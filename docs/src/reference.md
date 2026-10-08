# Reference

```@meta
CurrentModule = MemoizationKit
```

## Cache containers

```@docs
MemoizationKit.AbstractCache
LRU
ClockCache
resize!(::MemoizationKit.AbstractCache)
MemoizationKit.cache_stats
```

## Caching functions

```@docs
@cached
uncached
MemoizationKit.implementation
```

## Custom cache keys

See [Custom cache keys](keys.md) for canonical keys, custom equality, and sharing across methods.

```@docs
MemoizationKit.cachekey
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
MemoizationKit.cachesize
cache_dashboard
```

## Disk caching

```@docs
DiskCacheStyle
DiskCache
MemoizationKit.diskversion
MemoizationKit.disk_artifact
disk_cache_info
MemoizationKit.disk_cache_stats
empty_disk_caches!
export_disk_cache
disable_disk_caches!
enable_disk_caches!
```

## Hooks and timing

```@docs
MemoizationKit.instrument_label
enable_cache_timers!
disable_cache_timers!
```
