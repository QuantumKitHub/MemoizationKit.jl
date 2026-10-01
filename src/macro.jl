# -------------------------------------------------------------------------
# @cached macro — argument parsing
# -------------------------------------------------------------------------

"""
    splitdef(ex) -> NamedTuple

Parse a `@cached` function definition expression into its constituent parts.

Handles the three optional head layers Julia allows:

    function f(args...) where {P...} :: ReturnType
              ↑ :call    ↑ :where      ↑ ::(2-arg)

Returns a `NamedTuple` with fields:
- `fname` — function name symbol
- `arg` — full argument expression (possibly with gensym'd name for anonymous `::T` args)
- `arg_name` — argument name symbol
- `arg_type` — argument type expression, or `nothing` if untyped
- `params` — type parameters from `where {...}`, or `[]`
- `typed` — `true` if a return type annotation is present
- `typeex` — return type expression, or `nothing`
- `fbody` — function body expression

Only single-argument functions without keyword arguments or default values are supported.
"""
function splitdef(ex)
    Meta.isexpr(ex, :function) ||
        error("@cached: can only be used on function definitions")
    head, fbody = ex.args

    # Peel off :where  →  f(args...)::RT where {P...}
    params = Any[]
    if Meta.isexpr(head, :where)
        params = head.args[2:end]
        head = head.args[1]
    end

    # Peel off ::ReturnType  →  f(args...)::RT
    typeex = nothing
    if Meta.isexpr(head, :(::))
        typeex = head.args[2]
        head = head.args[1]
    end

    Meta.isexpr(head, :call) ||
        error("@cached: can only be used on function definitions")

    fname = head.args[1]
    raw_args = head.args[2:end]
    typed = typeex !== nothing

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
        g = gensym()
        arg = Expr(:(::), g, raw.args[1])
        arg_name = g
        arg_type = raw.args[1]
        # x::T  — named typed arg
    elseif Meta.isexpr(raw, :(::))
        arg = raw
        arg_name = raw.args[1]
        arg_type = raw.args[2]
        # x  — plain untyped arg
    else
        raw isa Symbol || error("@cached: unsupported argument form `$raw`")
        arg = raw
        arg_name = raw
        arg_type = :Any
    end

    return (; fname, arg, arg_name, arg_type, params, typed, typeex, fbody)
end

# Add :where type parameters to an expression, if any.
function _add_params(expr, params)
    isempty(params) && return expr
    return Expr(:where, expr, params...)
end

# -------------------------------------------------------------------------
# @cached macro — code generators
# -------------------------------------------------------------------------

# Generate: function f(::NoCache, arg) where {...}; body; end
# The implementation lives here — body is taken verbatim from the user's definition.
function _cached_nocache_def(d)
    return :(
        function $(d.fname)(::NoCache, $(d.arg)) where {$(d.params...)}
            $(d.fbody)
        end
    )
end

# Generate the dispatch wrapper:
#   function f(arg) where {...}
#       f(CacheStyle(f, arg_name), arg_name)[::ReturnType]
#   end
function _cached_dispatch_def(d)
    return :(
        function $(d.fname)($(d.arg)) where {$(d.params...)}
            style = CacheStyle($(d.fname), $(d.arg_name))
            $(d.typed ? :(result::$(d.typeex)) : :(result)) = $(d.fname)(style, $(d.arg_name))
            return result
        end
    )
end

# Generate the TaskLocalCache method:
#   function f(::TaskLocalCache{D}, arg) where {..., D}
#       _cache::D = get!(task_local_storage(), _tasklocal_key(f)) do; D(); end
#       get!(_cache, arg_name) do; f(NoCache(), arg_name); end[::ReturnType]
#   end
function _cached_tasklocal_def(d)
    # avoid name collisions
    Dvar = gensym(:D)
    cachevar = gensym(:cache)
    task_local_key = gensym(Symbol(:tasklocal_, d.fname))
    resultvar = gensym(:result)

    return :(
        function $(d.fname)(::TaskLocalCache{$Dvar}, $(d.arg)) where {$Dvar, $(d.params...)}
            cache::D = get!(task_local_storage(), $task_local_key) do
                Dvar()
            end
            $(d.typed ? :($resultvar::$(d.typeex)) : resultvar) = get!($cachevar, $(d.arg.name)) do
                $(d.fname)(NoCache(), $(d.arg_name))
            end
            return $resultvar
        end
    )
end

# Generate the GlobalLRUCache fallback method (lazy, not precompilation-safe).
#
# Emits a fallback with the same static type annotation as the user wrote:
#   function f(strategy::GlobalLRUCache, arg[::AnnotationType]) where {...}
#       _T  = typeof(arg)
#       _lru = _ensure_global_lru!(f, _T, V)   # creates LRU{T,V} on first call
#       _eval_global_method!(f, _T, _lru, @__MODULE__)  # Core.eval specialized method
#       Base.invokelatest(f, strategy, arg)
#   end
#   _register_static_sig!(sig_key, f)   # duplicate-detection + inner-dict init
#
# On the first call for a concrete type T, a specialized f(::GlobalLRUCache, arg::T)
# method is Core.eval'd into the caller's module with the LRU embedded by value.
# Subsequent calls for the same T dispatch directly to the specialized method.
function _cached_global_def(d)
    V = d.typed ? d.typeex : :Any
    sig_key = _sig_string(d.fname, d.arg_name, d.arg_type)

    fallback_fcall = _add_params(:($(d.fname)(strategy::GlobalLRUCache, $(d.arg))), d.params)
    fallback_body = quote
        local _T = typeof($(d.arg_name))
        local _lru = $(_ensure_global_lru!)($(d.fname), _T, $V)
        $(_eval_global_method!)($(d.fname), _T, _lru, @__MODULE__)
        return Base.invokelatest($(d.fname), strategy, $(d.arg_name))
    end

    return quote
        $(Expr(:function, fallback_fcall, fallback_body))
        $(_register_static_sig!)($(sig_key), $(d.fname))
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
- `f(::GlobalLRUCache, arg)` — process-wide LRU cache; the LRU is stored in a
  two-level `IdDict` (`GLOBAL_CACHE_TABLE[f][T]`) and created lazily on the first
  call for each concrete argument type `T`

Each `@cached` call creates a typed `LRU{T,V}` per concrete argument type `T`
encountered at runtime, where `V` comes from the return type annotation (falls back to `Any`).
Multiple `@cached` calls for the same function with different signatures are allowed.

This macro is **not precompilation-safe** (uses `Core.eval` to specialise methods at runtime).

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
    d = splitdef(ex)
    return esc(
        quote
            $(_cached_nocache_def(d))
            $(_cached_dispatch_def(d))
            $(_cached_tasklocal_def(d))
            $(_cached_global_def(d))
        end
    )
end
