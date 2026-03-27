# -------------------------------------------------------------------------
# Cache management API
# -------------------------------------------------------------------------

"""
    caches_for(f::Function) -> Vector

Return all per-signature LRU caches registered for function `f`.
"""
function caches_for(f::Function)
    return [PER_SIG_CACHES[k] for k in get(_FUNC_TO_SIG_KEYS, f, String[])]
end

"""
    empty_globalcaches!()

Clear all registered global LRU caches. Note that this also resets hit/miss statistics.
"""
function empty_globalcaches!()
    foreach(empty!, values(PER_SIG_CACHES))
    return nothing
end

"""
    set_cache_size!(f::Function, newsize::Int)
    set_cache_size!(sig::String, newsize::Int)

Resize the global LRU cache(s) for `f` (all signatures) or a specific `sig` to `newsize`
entries (count-based). If a cache is currently byte-based, it is switched to count-based
and existing entries are discarded.

```julia
set_cache_size!(myf, 50_000)
set_cache_size!("myf(::Int)", 50_000)
```
"""
function set_cache_size!(f::Function, newsize::Int)
    keys = get(_FUNC_TO_SIG_KEYS, f, nothing)
    keys === nothing &&
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    for k in keys
        _set_cache_size_by_key!(k, newsize)
    end
    return nothing
end

function set_cache_size!(sig::String, newsize::Int)
    haskey(PER_SIG_CACHES, sig) || throw(ArgumentError("No global cache registered for signature \"$sig\""))
    _set_cache_size_by_key!(sig, newsize)
    return nothing
end

function _set_cache_size_by_key!(sig::String, newsize::Int)
    lru = PER_SIG_CACHES[sig]
    if _is_bytesize(lru)
        empty!(lru)
        lru.by = _COUNT_BY
    end
    resize!(lru; maxsize = newsize)
    return nothing
end

"""
    set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])
    set_cache_bytesize!(sig::String, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])

Resize the global LRU cache(s) for `f` (all signatures) or a specific `sig` to `newsize`
bytes (byte-based). `by` is the function used to measure each cached value's size; it
defaults to [`GLOBALCACHE_SIZE_FUNCTION`](@ref). Existing entries are always discarded.

```julia
set_cache_bytesize!(myf, 100_000_000)               # 100 MB, default measurer
set_cache_bytesize!(myf, 50_000_000; by = sizeof)   # cheaper estimator
```
"""
function set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])
    keys = get(_FUNC_TO_SIG_KEYS, f, nothing)
    keys === nothing &&
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    for k in keys
        _set_cache_bytesize_by_key!(k, newsize; by)
    end
    return nothing
end

function set_cache_bytesize!(sig::String, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])
    haskey(PER_SIG_CACHES, sig) || throw(ArgumentError("No global cache registered for signature \"$sig\""))
    _set_cache_bytesize_by_key!(sig, newsize; by)
    return nothing
end

function _set_cache_bytesize_by_key!(sig::String, newsize::Int; by)
    lru = PER_SIG_CACHES[sig]
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
