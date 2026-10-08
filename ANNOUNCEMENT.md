**[ANN] MemoizationKit.jl: memoization with bounded memory, disk persistence, and a live dashboard**

MemoizationKit.jl v0.1.0 memoizes expensive Julia functions and gives you tools to manage the caches: limit memory, keep results across runs, and see what they're doing.

```julia
using MemoizationKit

@cached function fib(n::Int)::BigInt
    n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2)
end

fib(100)                   # compute and cache
cache_info(fib)            # size and hit/miss statistics
set_cache_size!(fib, 1000) # bound the cache
```

**Features**

- **Bounded storage:** Clock and LRU eviction, with limits in entries or bytes across all methods of a function.
- **Disk persistence:** load SQLite.jl to keep results across runs, or ship precomputed results as artifacts.
  Lookups go RAM, then artifact, then local database, then computation.
- **Live dashboard:** load Tachikoma.jl and call `cache_dashboard()` to browse hit rates, sizes, and activity for RAM and disk caches.
  You can also clear or resize caches from the terminal.
- **Fast RAM hits:** return-type inference is preserved, and RAM hits don't allocate for concrete keys with the built-in containers.
- **Strategies by function and argument type:** shared, task-local, or no caching via `CacheStyle`.
- **Custom keys:** `MemoizationKit.cachekey` lets equivalent inputs share a result, and `Hashed` customizes hashing and equality.
- **Configuration and profiling:** Preferences set defaults per package or function, and TimerOutputs.jl integration profiles lookups and computations.

If a single in-memory cache is all you need, Memoize.jl or Memoization.jl with an LRU container may already be enough.
MemoizationKit targets workloads where the cache needs ongoing management.
The docs include a comparison.

Requires Julia 1.10 or later.
Install with `Pkg.add("MemoizationKit")`.

- Docs: https://quantumkithub.github.io/MemoizationKit.jl/stable/
- Source: https://github.com/QuantumKitHub/MemoizationKit.jl

Feedback, issues, and PRs are welcome.
