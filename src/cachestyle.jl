"""
    CacheStyle

Supertype of the caching strategies used by [`@cached`](@ref) functions.

The strategy for a call `f(args...)` is chosen by `CacheStyle(f, args...)`, which defaults to
[`GlobalCache()`](@ref GlobalCache). Specialize it to change the strategy per function or argument type:

```julia
Cached.CacheStyle(::typeof(f), x::SmallKey) = NoCache()
Cached.CacheStyle(::typeof(f), x::ThreadedKey) = TaskLocalCache{LRU}()
```

See also [`NoCache`](@ref), [`GlobalCache`](@ref), [`TaskLocalCache`](@ref).
"""
abstract type CacheStyle end

"""
    NoCache()

Strategy that calls the implementation every time.
"""
struct NoCache <: CacheStyle end

"""
    GlobalCache{C}()
    GlobalCache()

Strategy that stores results in one process-wide cache per function, of container type
`C <: AbstractCache`. Without `C`, the container is the one set by the `container` preference
(`ClockCache` by default), so that a `CacheStyle` method can return the default strategy.
"""
struct GlobalCache{C} <: CacheStyle
    function GlobalCache{C}() where {C}
        C <: AbstractCache || throw(ArgumentError("GlobalCache requires an AbstractCache, got $C"))
        return new{C}()
    end
end

"""
    GlobalLRUCache()

Alias for `GlobalCache{LRU}()`.
"""
const GlobalLRUCache = GlobalCache{LRU}

GlobalCache() = GlobalCache{DEFAULT_CONTAINER}()

"""
    TaskLocalCache{C}()
    TaskLocalCache()

Strategy that stores results in caches local to the current task, of container type `C`.
`C` is either an `AbstractCache` or an `AbstractDict` type such as `Dict`; if it is not
already concrete, it is completed to `C{K, V}`. Without `C`, the container is the one set by
the `container` preference. Task-local caches need no locking but are not shared, not bounded
unless `C` is, and are not visible to [`cache_info`](@ref).
"""
struct TaskLocalCache{C} <: CacheStyle end

TaskLocalCache() = TaskLocalCache{DEFAULT_CONTAINER}()

CacheStyle(f, args...) = GlobalCache()
