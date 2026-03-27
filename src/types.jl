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
