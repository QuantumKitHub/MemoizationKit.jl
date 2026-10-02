# Cached.jl

```@meta
CurrentModule = Cached
```

Transparent, strategy-aware memoization for Julia functions.

!!! warning
    This package is under active development and its API may still change.

```julia
using Cached

@cached function fusion(a, b; normalize = true)
    # expensive computation
end

fusion(1, 2)              # computed
fusion(1, 2)              # looked up in fusion's cache; the result is still inferred
uncached(fusion, 1, 2)    # bypasses the cache

# choose the strategy per function and argument type
Cached.CacheStyle(::typeof(fusion), a::Int, b::Int) = TaskLocalCache{LRU}()

cache_info(fusion)        # hit/miss statistics
cache_info(MyPackage)     # ... of all cached functions of a module, empty_caches! likewise
set_cache_size!(fusion, 1_000)
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
- With Tachikoma.jl loaded, [`cache_dashboard`](@ref) opens a live terminal dashboard; see
  [Dashboard](dashboard.md).
- With TimerOutputs.jl loaded, [`enable_cache_timers!`](@ref) times lookups and computations
  per package; see [Timing](timing.md).
