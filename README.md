# Cached.jl

A Julia package for transparently memoizing function results.

## Quick start

```julia
using Cached

@cached function expensive(x)
    sleep(1)          # simulate work
    return x^2
end

expensive(3)   # computed (cache miss)
expensive(3)   # returned from cache instantly
```

`@cached` wraps a function definition and adds three cache-strategy methods. The strategy is
selected at call time via `CacheStyle(f, args...)`, which defaults to `GlobalLRUCache`.

## Cache strategies

| Strategy | Behaviour |
|---|---|
| `GlobalLRUCache()` | Process-wide LRU cache shared across all tasks (default) |
| `TaskLocalCache{D}()` | Per-task cache using a dict of type `D`; tasks are isolated |
| `NoCache()` | No caching; calls the implementation on every invocation |

Call with an explicit strategy to bypass the default:

```julia
expensive(NoCache(), 3)          # always recomputes
expensive(GlobalLRUCache(), 3)   # explicit global cache lookup
```

## Customising the strategy

Override `CacheStyle` for specific argument types:

```julia
# Disable caching for expensive objects that shouldn't be kept in memory
Cached.CacheStyle(::typeof(expensive), ::BigMatrix) = NoCache()

# Use task-local caching in multi-threaded code
Cached.CacheStyle(::typeof(expensive), ::ThreadSafeKey) = TaskLocalCache{Dict{Any,Any}}()
```

## Return type annotation

An optional `::ReturnType` annotation is asserted at every cache entry point, which helps
the compiler infer return types through the cache layer:

```julia
@cached function lookup(key)::MyResultType
    # ... expensive computation ...
end
```

## Managing cache sizes

By default, global LRU caches are byte-based with a 64 GiB limit (measured via
`Base.summarysize`). Adjust sizes after loading:

```julia
# Count-based: keep at most 10 000 entries
set_cache_size!(expensive, 10_000)

# Byte-based: keep at most 500 MB, using a cheaper size estimator
set_cache_bytesize!(expensive, 500_000_000; by = sizeof)
```

To change the default for all newly created caches (persisted to `LocalPreferences.toml`;
requires restarting Julia):

```julia
set_default_cache_bytesize!(500_000_000)   # 500 MB
set_default_cache_bytesize!(nothing)        # revert to count-based (10 000 entries)
```

## Inspecting caches

```julia
global_cache_info()
```

```
Cache Usage Summary (2 caches)
┌───────────┬───────┬────────┬──────────┬──────┬───────────────────┐
│ Name      │ Hits  │ Misses │ Hit rate │ Fill │ Memory            │
├───────────┼───────┼────────┼──────────┼──────┼───────────────────┤
│ expensive │  1234 │     56 │   95.7%  │   42 │  3.2 MB / 64.0 GB │
│ lookup    │   890 │    123 │   87.9%  │   31 │  1.8 MB / 64.0 GB │
└───────────┴───────┴────────┴──────────┴──────┴───────────────────┘
```

All registered caches are also accessible programmatically via `GLOBAL_CACHES`.

Clear all caches (resets hit/miss counters as well):

```julia
empty_globalcaches!()
```

## Constraints

- `@cached` can only be used **once per function name**. Add dispatch variants via
  `CacheStyle` overrides rather than multiple `@cached` calls.
- Keyword arguments and default argument values are not supported.
- Cache keys use Julia's `isequal` semantics — in particular, `isequal(3, 3.0) == true`,
  so integer-valued floats share a cache entry with their integer counterparts.
