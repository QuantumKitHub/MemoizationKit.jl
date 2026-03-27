# -------------------------------------------------------------------------
# @cached macro — argument parsing
# -------------------------------------------------------------------------

# Decompose a `function` expression into its constituent parts.
# Returns (; fname, params, typeex, typed, raw_args, fbody).
# Handles the three optional head layers Julia allows:
#   function f(args...) where {P...} :: ReturnType
#             ↑ :call    ↑ :where      ↑ ::(2-arg)
function _splitdef(ex)
    Meta.isexpr(ex, :function) ||
        error("@cached: can only be used on function definitions")
    head, fbody = ex.args

    # Peel off :where  →  f(args...)::RT where {P...}
    params = Any[]
    if Meta.isexpr(head, :where)
        params = head.args[2:end]
        head   = head.args[1]
    end

    # Peel off ::ReturnType  →  f(args...)::RT
    typeex = nothing
    if Meta.isexpr(head, :(::))
        typeex = head.args[2]
        head   = head.args[1]
    end

    Meta.isexpr(head, :call) ||
        error("@cached: can only be used on function definitions")

    fname    = head.args[1]
    raw_args = head.args[2:end]
    return (; fname, params, typeex, typed = typeex !== nothing, raw_args, fbody)
end

# Parse a complete @cached function definition into a NamedTuple.
# Calls _splitdef for structural decomposition, then applies @cached-specific validation.
# Only single-argument functions are supported.
function _parse_cached_def(ex)
    (; fname, params, typeex, typed, raw_args, fbody) = _splitdef(ex)

    # Reject keyword arguments
    if !isempty(raw_args) && Meta.isexpr(raw_args[1], :parameters)
        error("@cached: keyword arguments are not supported (function :$fname)")
    end

    # Reject default values
    for a in raw_args
        Meta.isexpr(a, :kw) &&
            error("@cached: default argument values are not supported (function :$fname)")
    end

    # Enforce single argument
    length(raw_args) == 1 ||
        error("@cached: only single-argument functions are supported (function :$fname)")

    raw = raw_args[1]
    # ::T  — anonymous typed arg; gensym a name so the signature stays valid
    if Meta.isexpr(raw, :(::)) && length(raw.args) == 1
        g        = gensym()
        arg      = Expr(:(::), g, raw.args[1])
        arg_name = g
        arg_type = raw.args[1]
    # x::T  — named typed arg
    elseif Meta.isexpr(raw, :(::))
        arg      = raw
        arg_name = raw.args[1]
        arg_type = raw.args[2]
    # x  — plain untyped arg
    else
        raw isa Symbol || error("@cached: unsupported argument form `$raw`")
        arg      = raw
        arg_name = raw
        arg_type = nothing
    end

    return (; fname, arg, arg_name, arg_type, params, typed, typeex, fbody)
end

# Add :where type parameters to an expression, if any.
function _add_params(expr, params)
    isempty(params) && return expr
    return Expr(:where, expr, params...)
end

# -------------------------------------------------------------------------
# @cached macro — K/V type inference helpers
# -------------------------------------------------------------------------

# True if `ex` contains any symbol from `names`.
function _expr_has_any(ex, names::Set{Symbol})
    ex isa Symbol && return ex in names
    ex isa Expr   && return any(a -> _expr_has_any(a, names), ex.args)
    return false
end

# True if `typeexpr` references any TypeVar declared in `params`.
function _has_typevars(typeexpr, params)
    isempty(params) && return false
    param_names = Set{Symbol}(p isa Symbol ? p : p.args[1] for p in params)
    return _expr_has_any(typeexpr, param_names)
end

# Human-readable signature string, e.g. "f(::Int)".
# Used as the registry key in PER_SIG_CACHES.
function _sig_string(fname::Symbol, arg_name::Symbol, arg_type)
    arg_str = arg_type !== nothing ? "::$(arg_type)" : string(arg_name)
    return "$(fname)($(arg_str))"
end

# Unique module-level constant name for a signature's LRU cache.
# e.g. f(x::Int) → :_cached_f__Int
function _cache_const_name(fname::Symbol, arg_name::Symbol, arg_type)
    tag   = arg_type !== nothing ? string(arg_type) : string(arg_name)
    clean = replace(tag, r"[^a-zA-Z0-9_]" => "_")
    return Symbol("_cached_$(fname)__$(clean)")
end

# -------------------------------------------------------------------------
# @cached macro — code generators
# -------------------------------------------------------------------------

# Generate: function f(::NoCache, arg) where {...}; body; end
# The implementation lives here — body is taken verbatim from the user's definition.
function _cached_nocache_def(d)
    fcall = _add_params(:($(d.fname)(::NoCache, $(d.arg))), d.params)
    Expr(:function, fcall, d.fbody)
end

# Generate the dispatch wrapper:
#   function f(arg) where {...}
#       f(CacheStyle(f, arg_name), arg_name)[::ReturnType]
#   end
function _cached_dispatch_def(d)
    fcall = _add_params(:($(d.fname)($(d.arg))), d.params)
    inner = :($(d.fname)(CacheStyle($(d.fname), $(d.arg_name)), $(d.arg_name)))
    body  = d.typed ? :($(inner)::$(d.typeex)) : inner
    Expr(:function, fcall, body)
end

# Generate the TaskLocalCache method:
#   function f(::TaskLocalCache{D}, arg) where {..., D}
#       _cache::D = get!(task_local_storage(), _tasklocal_key(f)) do; D(); end
#       get!(_cache, arg_name) do; f(NoCache(), arg_name); end[::ReturnType]
#   end
function _cached_tasklocal_def(d)
    Dvar      = gensym(:D)
    cachevar  = gensym(:cache)
    impl_call = :($(d.fname)(NoCache(), $(d.arg_name)))
    get_val   = :(get!($cachevar, $(d.arg_name)) do; $impl_call; end)
    d.typed && (get_val = :($(get_val)::$(d.typeex)))
    fcall = Expr(:where, :($(d.fname)(::TaskLocalCache{$Dvar}, $(d.arg))), d.params..., Dvar)
    # Embed _tasklocal_key by value so it resolves to the Cached module at any call site.
    body = quote
        $cachevar::$Dvar = get!(task_local_storage(), $(_tasklocal_key)($(d.fname))) do
            $Dvar()
        end
        $get_val
    end
    Expr(:function, fcall, body)
end

# Generate the GlobalLRUCache method (const-mode, precompilation-safe).
#
# Emits:
#   const _cached_f__T = _make_typed_global_lru(K, V)
#   function f(::GlobalLRUCache, arg) where {...}
#       get!(_cached_f__T, arg_name) do; f(NoCache(), arg_name); end[::ReturnType]
#   end
#   _register_per_sig_cache!(sig_key, _cached_f__T, f)
#
# The const is referenced by name in the method body — no dict lookup at call time.
# The compiler resolves the const to a direct pointer since it is a stable binding.
function _cached_global_def(d)
    K = (d.arg_type !== nothing && !_has_typevars(d.arg_type, d.params)) ? d.arg_type : :Any
    V = d.typed ? d.typeex : :Any

    sig_key    = _sig_string(d.fname, d.arg_name, d.arg_type)
    cache_name = _cache_const_name(d.fname, d.arg_name, d.arg_type)
    impl_call  = :($(d.fname)(NoCache(), $(d.arg_name)))
    get_val    = :(get!($cache_name, $(d.arg_name)) do; $impl_call; end)
    d.typed && (get_val = :($(get_val)::$(d.typeex)))
    fcall = _add_params(:($(d.fname)(::GlobalLRUCache, $(d.arg))), d.params)

    quote
        # Embed _make_typed_global_lru by value for cross-module safety.
        const $cache_name = $(_make_typed_global_lru)($K, $V)
        $(Expr(:function, fcall, get_val))
        $(_register_per_sig_cache!)($sig_key, $cache_name, $(d.fname))
    end
end

# -------------------------------------------------------------------------
# @cached macro
# -------------------------------------------------------------------------

"""
    @cached function f(arg) ... end
    @cached function f(arg)::ReturnType ... end

Define a cached version of a single-argument function. The caching strategy is
determined by `CacheStyle(f, arg)`, which defaults to `GlobalLRUCache()`.

The macro generates four methods for `f`:
- `f(arg)` — dispatch wrapper that selects a strategy via `CacheStyle`
- `f(::NoCache, arg)` — no caching; the implementation lives here
- `f(::TaskLocalCache{D}, arg)` — per-task cache using a dict of type `D`
- `f(::GlobalLRUCache, arg)` — process-wide LRU cache; the LRU is referenced
  via a module-level `const` (no dict lookup at call time)

Each `@cached` call creates its own typed `LRU{K,V}` where `K` is inferred from
the concrete argument type and `V` from the return type annotation (both fall back to `Any`).
Multiple `@cached` calls for the same function with different signatures are allowed.

This macro is **precompilation-safe**.

## Constraints
- Only single-argument functions are supported
- Keyword arguments and default values are not supported
- Calling `@cached` twice with the **same** signature is an error

## Return type annotation

An optional `::ReturnType` assertion is inserted at every cache-strategy entry point
(dispatch wrapper, GlobalLRUCache, TaskLocalCache), aiding type inference:

```julia
@cached function myf(key::Int)::Float64
    # expensive computation
end
```

## CacheStyle override

```julia
@cached function myf(key)
    # expensive computation
end

# Disable caching for a specific argument type
CacheStyle(::typeof(myf), ::MySpecialType) = NoCache()
```

See also: [`CacheStyle`](@ref), [`NoCache`](@ref),
[`TaskLocalCache`](@ref), [`GlobalLRUCache`](@ref)
"""
macro cached(ex)
    d = _parse_cached_def(ex)
    return esc(quote
        $(_cached_nocache_def(d))
        $(_cached_dispatch_def(d))
        $(_cached_tasklocal_def(d))
        $(_cached_global_def(d))
    end)
end
