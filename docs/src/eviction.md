# Eviction policies

```@meta
CurrentModule = MemoizationKit
```

When a RAM cache reaches its size limit, it removes entries to make room for new results.
MemoizationKit provides two policies: Clock (the default) and least recently used (LRU).
Both work with shared and task-local caches, and with limits in entries or measured value size.

## Clock: second chances

[`ClockCache`](@ref) approximates recent use with one reference bit per entry and a hand that walks the storage slots.
A hit sets the entry's bit.
When space is needed, the hand clears set bits and skips those entries, giving them a second chance.
It removes the first entry it finds with a clear bit and continues from that position on the next eviction.

New entries start with a clear bit: they get a second chance only after a cache hit.
For example, fill a three-entry cache with A, B, and C, then hit A.
Inserting D starts the hand at A, clears A's bit, and evicts B, whose bit is clear.
```@example clockcache
using MemoizationKit

cache = ClockCache{Symbol, Int}(; maxsize = 3)
for (key, value) in zip((:A, :B, :C), 1:3)
    cache[key] = value
end
cache[:A] # a hit
cache[:D] = 4
sort!(collect(keys(cache))) # B was evicted
```

Unlike LRU, Clock does not track the exact order of hits.
A recently inserted entry that has never been hit again can be evicted before an older entry that has been reused.

Choose Clock for approximate recency with little bookkeeping on hits: a hit updates a bit rather than a recency list.
Eviction may scan several slots to find a victim.

## LRU: exact recency

[`LRU`](@ref) keeps entries ordered by their last use.
A hit moves an entry to the most recently used position, and a new entry starts there too.
When space is needed, the least recently used entry is removed.

For example, fill a three-entry cache with A, B, and C, then hit A.
The order from least to most recently used becomes B, C, A, so inserting D evicts B.
```@example lru
using MemoizationKit

cache = LRU{Symbol, Int}(; maxsize = 3)
for (key, value) in zip((:A, :B, :C), 1:3)
    cache[key] = value
end
cache[:A] # a hit
cache[:D] = 4
sort!(collect(keys(cache))) # B was evicted
```

Unlike Clock, LRU always retains the exact recency order, even after several hits between evictions.

Choose LRU when that ordering suits the workload.
Maintaining the order requires more bookkeeping on hits, but choosing the next victim does not require a scan.
Neither policy guarantees a better hit rate for every workload; use the [dashboard](dashboard.md) or [timing](timing.md) to evaluate yours.

## Selecting a policy

```@example policy
using MemoizationKit
@cached expensive(x) = x^2
@cached other(x) = 2x

MemoizationKit.CacheStyle(::typeof(expensive), args...) = GlobalCache{LRU}()
MemoizationKit.CacheStyle(::typeof(other), args...) = TaskLocalCache{ClockCache}()

(CacheStyle(expensive, 3), CacheStyle(other, 3))
```

To set the default container for `GlobalCache()` and `TaskLocalCache()`, use the `container` preference in [Configuration](configuration.md).
Custom eviction policies can be supplied through the [cache interface](interface.md).

## Size limits

Both policies evict as many entries as needed to fit a new value or a reduced limit.
A value larger than the entire limit is returned without being stored.
Byte limits measure cached values, not keys or container overhead.
Shared caches use locks under either policy; computations run outside those locks.
Disk caches have no eviction policy; see [Disk caching](disk.md) for cleanup.
