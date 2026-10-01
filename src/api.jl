# -------------------------------------------------------------------------
# Cache management API
# -------------------------------------------------------------------------

"""
    caches_for(f::Function) -> Vector

Return all per-type LRU caches registered for function `f`.  Caches are created
lazily on the first call for each concrete argument type, so this returns an empty
vector until `f` has been called at least once via the `GlobalLRUCache` strategy.
"""
function caches_for(f::Function)
    table = get(GLOBAL_CACHE_TABLE, f, nothing)
    table === nothing && return Any[]
    return collect(values(table))
end

"""
    empty_globalcaches!()

Clear all registered global LRU caches. Note that this also resets hit/miss statistics.
"""
function empty_globalcaches!()
    for func_caches in values(GLOBAL_CACHE_TABLE)
        foreach(empty!, values(func_caches))
    end
    return nothing
end

"""
    set_cache_size!(f::Function, newsize::Int)

Resize all global LRU caches for `f` (all concrete-type specialisations) to `newsize`
entries (count-based). If a cache is currently byte-based, it is switched to count-based
and existing entries are discarded.

```julia
set_cache_size!(myf, 50_000)
```
"""
function set_cache_size!(f::Function, newsize::Int)
    table = get(GLOBAL_CACHE_TABLE, f, nothing)
    table === nothing &&
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    for lru in values(table)
        if _is_bytesize(lru)
            empty!(lru)
            lru.by = _COUNT_BY
        end
        resize!(lru; maxsize = newsize)
    end
    return nothing
end

"""
    set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])

Resize all global LRU caches for `f` (all concrete-type specialisations) to `newsize`
bytes (byte-based). `by` is the function used to measure each cached value's size; it
defaults to [`GLOBALCACHE_SIZE_FUNCTION`](@ref). Existing entries are always discarded.

```julia
set_cache_bytesize!(myf, 100_000_000)               # 100 MB, default measurer
set_cache_bytesize!(myf, 50_000_000; by = sizeof)   # cheaper estimator
```
"""
function set_cache_bytesize!(f::Function, newsize::Int; by = GLOBALCACHE_SIZE_FUNCTION[])
    table = get(GLOBAL_CACHE_TABLE, f, nothing)
    table === nothing &&
        throw(ArgumentError("No global cache registered for $(nameof(f))"))
    for lru in values(table)
        empty!(lru)
        lru.by = by
        resize!(lru; maxsize = newsize)
    end
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
