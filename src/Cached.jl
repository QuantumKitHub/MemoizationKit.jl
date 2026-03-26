module Cached

# -------------------------------------------------------------------------
# Exports
# -------------------------------------------------------------------------

export CacheStyle, NoCache, TaskLocalCache, GlobalLRUCache
export @cached
export GLOBAL_CACHES, DEFAULT_GLOBALCACHE_SIZE, GLOBALCACHE_SIZE_FUNCTION
export empty_globalcaches!, global_cache_info, set_cache_size!, set_cache_bytesize!
export set_default_cache_bytesize!

# -------------------------------------------------------------------------
# Imports
# -------------------------------------------------------------------------

using LRUCache
using Preferences
using Printf: @sprintf

# -------------------------------------------------------------------------
# Cache style types
# -------------------------------------------------------------------------

"""
    CacheStyle

Abstract type for cache strategies used by the `@cached` macro.

The default strategy is [`GlobalLRUCache`](@ref). Override it for specific
argument types by defining a method for `CacheStyle(::typeof(f), args...)`.

See also: [`NoCache`](@ref), [`TaskLocalCache`](@ref), [`GlobalLRUCache`](@ref), [`@cached`](@ref)
"""
abstract type CacheStyle end

"""
    NoCache <: CacheStyle

Cache strategy that disables caching. The function is called on every invocation.

See also: [`CacheStyle`](@ref), [`@cached`](@ref)
"""
struct NoCache <: CacheStyle end

"""
    TaskLocalCache{D <: AbstractDict} <: CacheStyle

Cache strategy that stores results in task-local storage using a dict of type `D`.
Each task maintains its own independent cache.

See also: [`CacheStyle`](@ref), [`@cached`](@ref)
"""
struct TaskLocalCache{D <: AbstractDict} <: CacheStyle end

"""
    GlobalLRUCache <: CacheStyle

Cache strategy that stores results in a process-wide LRU cache. This is the default.

The cache size can be configured via [`set_cache_size!`](@ref) or [`set_cache_bytesize!`](@ref)
and inspected with [`global_cache_info`](@ref).

See also: [`CacheStyle`](@ref), [`@cached`](@ref), [`DEFAULT_GLOBALCACHE_SIZE`](@ref)
"""
struct GlobalLRUCache <: CacheStyle end

"""
    CacheStyle(f, args...) -> CacheStyle

Return the cache strategy to use when calling `f(args...)`. Defaults to `GlobalLRUCache()`.

Override this for specific functions or argument types:
```julia
CacheStyle(::typeof(myf), ::MyType) = NoCache()
```
"""
CacheStyle(args...) = GlobalLRUCache()

# -------------------------------------------------------------------------
# Preferences and defaults
# -------------------------------------------------------------------------

# Loaded from LocalPreferences.toml at module load time.
const PREF_GLOBALCACHE_BYTESIZE::Bool = parse(Bool, @load_preference("globalcache_bytesize", "true"))

"""
    DEFAULT_GLOBALCACHE_SIZE

Default size for global LRU caches created by `@cached`.
64 GiB if byte-based sizing is active (the default), or 10 000 entries otherwise.
Configured via `LocalPreferences.toml`; see [`set_default_cache_bytesize!`](@ref).
"""
const DEFAULT_GLOBALCACHE_SIZE::Int = parse(
    Int, @load_preference("globalcache_size", string(PREF_GLOBALCACHE_BYTESIZE ? 2^36 : 10^4))
)

"""
    GLOBALCACHE_SIZE_FUNCTION

A `Ref{Function}` holding the default size measurer used by byte-based global LRU caches.
Initially `Base.summarysize`. Change it before loading packages that use `@cached` to
affect newly created caches, or use [`set_cache_bytesize!`](@ref) to update individual
caches after the fact.

```julia
GLOBALCACHE_SIZE_FUNCTION[] = sizeof  # use cheaper estimator globally
```
"""
const GLOBALCACHE_SIZE_FUNCTION = Ref{Function}(Base.summarysize)

# Sentinel `by` function for count-based LRU caches.
# lru.by === _COUNT_BY  ⟺  cache is count-based.
const _COUNT_BY = Returns(1)

# -------------------------------------------------------------------------
# Cache registry
# -------------------------------------------------------------------------

"""
    GLOBAL_CACHES

`IdDict{Function, LRU}` mapping each cached function to its global LRU cache object.
All caches registered via [`@cached`](@ref) appear here and can be inspected with
[`global_cache_info`](@ref).
"""
const GLOBAL_CACHES = IdDict{Function, LRU{Any,Any}}()

# -------------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------------

# Returns a new LRU configured from module-load-time preferences.
function _make_global_lru()
    if PREF_GLOBALCACHE_BYTESIZE
        return LRU{Any,Any}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = GLOBALCACHE_SIZE_FUNCTION[])
    else
        return LRU{Any,Any}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = _COUNT_BY)
    end
end

# True if the cache measures size in bytes rather than entry count.
_is_bytesize(lru::LRU) = lru.by !== _COUNT_BY

# Returns the task_local_storage key for function f's task-local cache.
_tasklocal_key(f::Function) = Symbol(:_tasklocal_, parentmodule(f), :_, nameof(f), :_cache)

# Register f → lru in GLOBAL_CACHES. Errors if f is already registered.
function _register_global_cache!(f::Function, lru::LRU{Any,Any})
    haskey(GLOBAL_CACHES, f) &&
        error("@cached: a global cache is already registered for $(nameof(f)). ",
              "@cached can only be used once per function name.")
    GLOBAL_CACHES[f] = lru
    return lru
end

# Look up the LRU cache for f. Embedded by value in generated GlobalLRUCache methods
# so that the lookup goes through the Cached module regardless of call site, and is
# safe across precompilation (no raw dict object embedded in compiled code).
_global_cache(f::Function) = GLOBAL_CACHES[f]

# -------------------------------------------------------------------------
# Cache management API
# -------------------------------------------------------------------------

"""
    empty_globalcaches!()

Clear all registered global LRU caches. Note that this also resets hit/miss statistics.
"""
function empty_globalcaches!()
    foreach(empty!, values(GLOBAL_CACHES))
    return nothing
end

"""
    set_cache_size!(f::Function, newsize::Int)

Resize the global LRU cache for `f` to `newsize` entries (count-based).
If the cache is currently byte-based, it is switched to count-based and existing entries
are discarded.

```julia
set_cache_size!(myf, 50_000)
```
"""
function set_cache_size!(f::Function, newsize::Int)
    haskey(GLOBAL_CACHES, f) ||
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    lru = GLOBAL_CACHES[f]
    if _is_bytesize(lru)
        empty!(lru)
        lru.by = _COUNT_BY
    end
    resize!(lru; maxsize = newsize)
    return nothing
end

"""
    set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])

Resize the global LRU cache for `f` to `newsize` bytes (byte-based).
`by` is the function used to measure each cached value's size; it defaults to
[`GLOBALCACHE_SIZE_FUNCTION`](@ref). Existing entries are always discarded.

```julia
set_cache_bytesize!(myf, 100_000_000)               # 100 MB, default measurer
set_cache_bytesize!(myf, 50_000_000; by = sizeof)   # cheaper estimator
```
"""
function set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])
    haskey(GLOBAL_CACHES, f) ||
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    lru = GLOBAL_CACHES[f]
    empty!(lru)
    lru.by = by
    resize!(lru; maxsize = newsize)
    return nothing
end

"""
    set_default_cache_bytesize!(bytes::Union{Nothing,Int})

Persist the default byte-size limit for global LRU caches to `LocalPreferences.toml`.
Pass `nothing` to revert to count-based sizing. **Requires restarting Julia** to take
effect since caches are created at module load time.

Use [`set_cache_bytesize!`](@ref) for immediate per-cache changes.

```julia
set_default_cache_bytesize!(500_000_000)  # default all new caches to 500 MB
set_default_cache_bytesize!(nothing)       # revert to count-based
```
"""
function set_default_cache_bytesize!(bytes::Union{Nothing,Int})
    if bytes === nothing
        @set_preferences!("globalcache_bytesize" => "false")
    else
        @set_preferences!("globalcache_bytesize" => "true", "globalcache_size" => string(bytes))
    end
    @info "Default cache byte size updated. Restart Julia for the change to take effect."
    return nothing
end

# -------------------------------------------------------------------------
# Cache visualisation
# -------------------------------------------------------------------------

function _format_bytes(n::Integer)
    n < 1024   && return string(n, " B")
    n < 1024^2 && return @sprintf("%.1f KB", n / 1024)
    n < 1024^3 && return @sprintf("%.1f MB", n / 1024^2)
    return @sprintf("%.1f GB", n / 1024^3)
end

function _table_hline(io, widths, left, mid, right)
    print(io, left)
    for (i, w) in enumerate(widths)
        print(io, "─"^(w + 2))
        print(io, i < length(widths) ? mid : right)
    end
    println(io)
end

function _table_row(io, cells, widths)
    print(io, "│")
    for (cell, w) in zip(cells, widths)
        print(io, " ", rpad(cell, w), " │")
    end
    println(io)
end

"""
    global_cache_info(io::IO = stdout)

Display a summary table of all registered global LRU caches, including hit/miss
statistics, fill level, and memory usage.

For count-based caches the Fill column shows `current/max` entries and Memory shows
estimated bytes. For byte-based caches Fill shows entry count and Memory shows
`current/max` as human-readable byte counts.
"""
function global_cache_info(io::IO = stdout)
    if isempty(GLOBAL_CACHES)
        println(io, "No global caches registered.")
        return
    end

    header = ("Name", "Hits", "Misses", "Hit rate", "Fill", "Memory")

    sorted_pairs = sort!(
        [(f, lru, LRUCache.cache_info(lru)) for (f, lru) in GLOBAL_CACHES];
        by = p -> string(nameof(p[1]))
    )

    rows = map(sorted_pairs) do (f, lru, info)
        hits    = info.hits
        misses  = info.misses
        total   = hits + misses
        hitrate = total == 0 ? "N/A" : @sprintf("%.1f%%", 100.0 * hits / total)
        fill, mem = if _is_bytesize(lru)
            string(length(lru)),
            "$(_format_bytes(info.currentsize)) / $(_format_bytes(info.maxsize))"
        else
            "$(info.currentsize)/$(info.maxsize)",
            _format_bytes(Base.summarysize(lru))
        end
        (string(nameof(f)), string(hits), string(misses), hitrate, fill, mem)
    end

    widths = [length(h) for h in header]
    for row in rows
        for i in eachindex(widths)
            widths[i] = max(widths[i], length(row[i]))
        end
    end

    n = length(GLOBAL_CACHES)
    println(io, "Cache Usage Summary (", n, " cache", n == 1 ? "" : "s", ")")
    _table_hline(io, widths, '┌', '┬', '┐')
    _table_row(io, header, widths)
    _table_hline(io, widths, '├', '┼', '┤')
    for row in rows
        _table_row(io, row, widths)
    end
    _table_hline(io, widths, '└', '┴', '┘')
    return
end

# -------------------------------------------------------------------------
# @cached macro — argument parsing
# -------------------------------------------------------------------------

# Represents one parsed argument from a @cached function definition.
struct ParsedArg
    sig_expr :: Any     # expression for the function signature (e.g. :(x::T), :(rest...), :(##g::T))
    name     :: Symbol  # variable name (gensym for anonymous ::T args)
    key_expr :: Any     # contribution to the cache-key tuple  (:x for regular, :(rest...) for varargs)
end

# Parse a single argument AST node into a ParsedArg.
function _parse_arg(arg)
    # Anonymous typed arg: ::T  (single-child :: expression, no name)
    if Meta.isexpr(arg, :(::)) && length(arg.args) == 1
        g = gensym()
        return ParsedArg(Expr(:(::), g, arg.args[1]), g, g)
    end
    # Vararg: x... or x::T...
    if Meta.isexpr(arg, :(...))
        inner = arg.args[1]
        name  = Meta.isexpr(inner, :(::)) ? inner.args[1] : inner
        name isa Symbol || error("@cached: unsupported argument form: $arg")
        return ParsedArg(arg, name, Expr(:(...), name))
    end
    # Typed arg: x::T
    if Meta.isexpr(arg, :(::))
        name = arg.args[1]
        name isa Symbol || error("@cached: unsupported argument form: $arg")
        return ParsedArg(arg, name, name)
    end
    # Plain arg: x
    arg isa Symbol || error("@cached: unsupported argument form: $arg")
    return ParsedArg(arg, arg, arg)
end

# Parse a complete @cached function definition into a NamedTuple.
function _parse_cached_def(ex)
    Meta.isexpr(ex, :function) ||
        error("@cached: can only be used on function definitions")
    head = ex.args[1]

    # Strip :where type parameters
    if Meta.isexpr(head, :where)
        params = head.args[2:end]
        head   = head.args[1]
    else
        params = Any[]
    end

    # Strip ::ReturnType annotation
    if Meta.isexpr(head, :(::))
        typed  = true
        typeex = head.args[2]
        head   = head.args[1]
    else
        typed  = false
        typeex = nothing
    end

    Meta.isexpr(head, :call) ||
        error("@cached: can only be used on function definitions")
    fname    = head.args[1]
    raw_args = head.args[2:end]

    # Reject keyword arguments
    if !isempty(raw_args) && Meta.isexpr(raw_args[1], :parameters)
        error("@cached: keyword arguments are not supported (function :$fname)")
    end

    # Reject default values
    for arg in raw_args
        Meta.isexpr(arg, :kw) &&
            error("@cached: default argument values are not supported (function :$fname)")
    end

    parsed_args = map(_parse_arg, raw_args)
    return (; fname, parsed_args, params, typed, typeex, fbody = ex.args[2])
end

# Add :where type parameters to an expression, if any.
function _add_params(expr, params)
    isempty(params) && return expr
    return Expr(:where, expr, params...)
end

# -------------------------------------------------------------------------
# @cached macro — code generators
# -------------------------------------------------------------------------

# Generate: function f(::NoCache, args...) where {...}; body; end
# The implementation lives here — body is taken verbatim from the user's definition.
function _cached_nocache_def(d)
    sig_exprs = [a.sig_expr for a in d.parsed_args]
    fcall     = _add_params(Expr(:call, d.fname, :(::NoCache), sig_exprs...), d.params)
    return Expr(:function, fcall, d.fbody)
end

# Generate the dispatch wrapper:
#   function f(args...) where {...}
#       f(CacheStyle(f, args...), args...)[::ReturnType]
#   end
function _cached_dispatch_def(d)
    sig_exprs = [a.sig_expr for a in d.parsed_args]
    key_exprs = [a.key_expr for a in d.parsed_args]
    fcall     = _add_params(Expr(:call, d.fname, sig_exprs...), d.params)
    inner     = Expr(:call, d.fname, Expr(:call, :CacheStyle, d.fname, key_exprs...), key_exprs...)
    body      = d.typed ? Expr(:(::), inner, d.typeex) : inner
    return Expr(:function, fcall, body)
end

# Generate the TaskLocalCache method:
#   function f(::TaskLocalCache{D}, args...) where {..., D}
#       _cache::D = get!(task_local_storage(), _tasklocal_key(f)) do; D(); end
#       get!(_cache, (args...)) do; f(NoCache(), args...); end[::ReturnType]
#   end
function _cached_tasklocal_def(d)
    Dvar      = gensym(:D)
    sig_exprs = [a.sig_expr for a in d.parsed_args]
    key_exprs = [a.key_expr for a in d.parsed_args]
    fcall     = Expr(:where, Expr(:call, d.fname, :(::TaskLocalCache{$Dvar}), sig_exprs...), d.params..., Dvar)
    cachevar  = gensym(:cache)
    key       = Expr(:tuple, key_exprs...)
    impl_call = Expr(:call, d.fname, :(NoCache()), key_exprs...)

    # Embed _tasklocal_key by value so it resolves to the Cached module at any call site.
    get_cache = :($cachevar::$Dvar = get!(task_local_storage(), $(_tasklocal_key)($(d.fname))) do
        $Dvar()
    end)
    get_val = :(get!($cachevar, $key) do
        $impl_call
    end)
    get_val = d.typed ? Expr(:(::), get_val, d.typeex) : get_val

    return Expr(:function, fcall, Expr(:block, get_cache, get_val))
end

# Generate the GlobalLRUCache method and a top-level registration call:
#
#   function f(::GlobalLRUCache, args...) where {...}
#       get!(_global_cache(f), (args...)) do; f(NoCache(), args...); end[::ReturnType]
#   end
#   _register_global_cache!(f, _make_global_lru())
#
# Note: we cannot use a let-captured LRU because defining a method inside a let block
# creates a LOCAL generic function rather than adding to the global one (Julia scoping).
# _global_cache and _register_global_cache! are embedded by value so they resolve to
# the Cached module regardless of where @cached is used.
function _cached_global_def(d)
    sig_exprs = [a.sig_expr for a in d.parsed_args]
    key_exprs = [a.key_expr for a in d.parsed_args]
    key       = Expr(:tuple, key_exprs...)
    impl_call = Expr(:call, d.fname, :(NoCache()), key_exprs...)
    fcall     = _add_params(Expr(:call, d.fname, :(::GlobalLRUCache), sig_exprs...), d.params)

    get_val = :(get!($(_global_cache)($(d.fname)), $key) do
        $impl_call
    end)
    get_val = d.typed ? Expr(:(::), get_val, d.typeex) : get_val

    global_method = Expr(:function, fcall, get_val)
    registration  = :($(_register_global_cache!)($(d.fname), $(_make_global_lru)()))

    return Expr(:block, global_method, registration)
end

# -------------------------------------------------------------------------
# @cached macro
# -------------------------------------------------------------------------

"""
    @cached function f(args...) ... end
    @cached function f(args...)::ReturnType ... end

Define a cached version of a function. The caching strategy is determined by
`CacheStyle(f, args...)`, which defaults to `GlobalLRUCache()`.

The macro generates four methods for `f`:
- `f(args...)` — dispatch wrapper that selects a strategy via `CacheStyle`
- `f(::NoCache, args...)` — no caching; the implementation lives here
- `f(::TaskLocalCache{D}, args...)` — per-task cache using a dict of type `D`
- `f(::GlobalLRUCache, args...)` — process-wide LRU cache looked up via `GLOBAL_CACHES`

## Constraints
- Can only be used **once per function name** — use `CacheStyle` overrides for per-type dispatch
- Keyword arguments and default values are not supported

## Return type annotation

An optional `::ReturnType` assertion is inserted at every cache-strategy entry point
(dispatch wrapper, GlobalLRUCache, TaskLocalCache), aiding type inference:

```julia
@cached function myf(key)::MyReturnType
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

See also: [`CacheStyle`](@ref), [`NoCache`](@ref), [`TaskLocalCache`](@ref), [`GlobalLRUCache`](@ref)
"""
macro cached(ex)
    length((:_,)) == 1 || error("@cached: expected 1 argument")  # guard against misuse
    d = _parse_cached_def(ex)
    # Check for double registration at macro-expansion time so no methods are
    # redefined (and no "method overwritten" warnings are emitted).
    if isdefined(__module__, d.fname)
        f = getfield(__module__, d.fname)
        if f isa Function && haskey(GLOBAL_CACHES, f)
            error("@cached: a global cache is already registered for $(d.fname). ",
                  "@cached can only be used once per function name.")
        end
    end
    return esc(Expr(:block,
        _cached_nocache_def(d),
        _cached_dispatch_def(d),
        _cached_tasklocal_def(d),
        _cached_global_def(d),
    ))
end

end # module Cached
