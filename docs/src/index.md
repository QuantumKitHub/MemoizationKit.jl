# Cached.jl

```@meta
CurrentModule = Cached
```

Transparent, strategy-aware memoization for Julia functions.

!!! warning
    This package is under active development and its API may still change.

```julia
using Cached

@cached function combine(a, b; normalize = true)
    # expensive computation
end

combine(1, 2)              # computed
combine(1, 2)              # looked up in combine's cache; the result is still inferred
uncached(combine, 1, 2)    # bypasses the cache

# choose the strategy per function and argument type
Cached.CacheStyle(::typeof(combine), a::Int, b::Int) = TaskLocalCache{LRU}()

cache_info(combine)        # hit/miss statistics
cache_info(MyPackage)     # ... of all cached functions of a module, empty_caches! likewise
set_cache_size!(combine, 1_000)
```

- [`@cached`](@ref) works on any method definition: positional, default, varargs and keyword
  arguments, `where` clauses, qualified names, operators and callable objects.
- Each function has one cache, whose `maxsize` (in entries or bytes) is the budget for all its
  signatures together. Calls stay type-stable, and cache hits do not allocate.
- [`CacheStyle`](@ref) selects the strategy per function and argument type: a shared
  [`GlobalCache`](@ref) (the default, a [`ClockCache`](@ref)), a [`TaskLocalCache`](@ref), or
  [`NoCache`](@ref).
- Default sizes are configured per package and per function through preferences; see
  [Configuration](configuration.md).
- With SQLite.jl loaded, [`DiskCacheStyle`](@ref) keeps results on disk as well, below the
  RAM cache, in one database per function and node; see [Disk caching](disk.md).
- With Tachikoma.jl loaded, [`cache_dashboard`](@ref) opens a live terminal dashboard; see
  [Dashboard](dashboard.md).
- With TimerOutputs.jl loaded, [`enable_cache_timers!`](@ref) times lookups and computations
  per package; see [Timing](timing.md).

## Sharing results between inputs

Specialize [`Cached.cachekey`](@ref) to share results between equivalent inputs. Return a
canonical key to group calls, including calls to different methods or argument types, or use
[`Hashed`](@ref) to customize hashing and equality without changing the input type.

```julia
@cached allocation_shape(x; copies = 1) = (length(x), copies)
Cached.cachekey(::typeof(allocation_shape), x; copies = 1) = (length(x), copies)

allocation_shape([1, 2])
allocation_shape((3, 4)) # same key, shares the cached result
```

The function body receives the original arguments. See [Custom cache keys](keys.md) for
working examples, keyword handling, equality requirements, and RAM and disk behavior.
