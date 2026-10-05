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

## Custom cache keys

See [Custom cache keys](keys.md) for canonical keys, custom equality, and sharing across methods.

```@docs
Cached.cachekey
Hashed
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
cache_dashboard
```

## Disk caching

```@docs
DiskCacheStyle
DiskCache
Cached.diskversion
Cached.disk_artifact
disk_cache_info
Cached.disk_cache_stats
empty_disk_caches!
export_disk_cache
disable_disk_caches!
enable_disk_caches!
```

## Hooks and timing

```@docs
Cached.instrument_label
enable_cache_timers!
disable_cache_timers!
```
