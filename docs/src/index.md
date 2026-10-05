# Cached.jl

```@meta
CurrentModule = Cached
```

Cached reuses the results of Julia functions called with the same arguments.
It is useful when repeated computations are expensive and their caches need limits, monitoring, or persistence.

- [`@cached`](@ref) keeps ordinary Julia method signatures, including defaults, keywords, varargs, and `where` parameters.
- [`CacheStyle`](@ref) selects shared, task-local, or uncached execution per function and argument type.
- Built-in [`ClockCache`](@ref) and [`LRU`](@ref) containers bound storage in entries or bytes.
  With concrete keys and an inferred concrete return type, RAM hits do not allocate.
- [`Cached.cachekey`](@ref) maps equivalent inputs to a shared result; see [Custom cache keys](keys.md).
- [Preferences](configuration.md) set defaults per package or function; runtime tools inspect, clear, and resize global caches.
- Optional extensions add [disk persistence](disk.md), a [terminal dashboard](dashboard.md), and [timing](timing.md).

## Quick start

Requires Julia 1.10 or later.
Add Cached to your environment with Julia's package manager:

```julia
using Pkg
Pkg.add("Cached")
```

```jldoctest
using Cached

@cached function fib(n::Int)::BigInt
    n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2)
end;

fib(100)

# output

354224848179261915075
```

Calling `fib(100)` again reuses the stored result.
By default, each function gets a shared Clock cache with room for 10,000 entries across all its cached methods.

Continue with [Usage](usage.md) for strategies and cache management, or [Why Cached?](comparison.md) for the motivation and comparison with other packages.
