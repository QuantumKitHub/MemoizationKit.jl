# Reference

```@meta
CurrentModule = Cached
```

## Cache containers

```@docs
Cached.AbstractCache
LRU
ClockCache
resize!(::Cached.AbstractCache)
Cached.cache_stats
```

## Caching functions

```@docs
@cached
uncached
Cached.implementation
```

## Strategies

```@docs
CacheStyle
NoCache
GlobalCache
GlobalLRUCache
TaskLocalCache
```

## Managing caches

```@docs
cache_info
empty_caches!
set_cache_size!
set_cache_preferences!
Cached.cachesize
```
