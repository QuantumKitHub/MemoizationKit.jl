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

## [Using Cached](@id usage)

### Memoizing a method

Put [`@cached`](@ref) before a method definition.
By default, its positional and keyword arguments form the cache key, and its body runs only on a miss.

```jldoctest powers
using Cached

@cached function powers(x::T, n::Int = 3; offset::T = zero(T))::Vector{T} where {T}
    [x^i + offset for i in 1:n]
end;

powers(2; offset = 1)

# output

3-element Vector{Int64}:
 3
 5
 9
```

The macro also supports varargs, qualified names, operators, and callable objects.
Anonymous functions are not supported.
Methods without `@cached` keep their usual behavior.

A return annotation is optional and may depend on `where` parameters.
Without one, Cached uses the inferred return type, falling back to `Any` if it is not concrete.
A type-stable body keeps calls inferred even though the shared cache holds results of different types.

Use [`uncached`](@ref) to call the body without reading or filling RAM or disk caches.
Supply all arguments, including defaults: defaults belong to the wrapper, not the uncached body.

```jldoctest powers
uncached(powers, 2, 3; offset = 1)

# output

3-element Vector{Int64}:
 3
 5
 9
```

### Choosing a strategy

Define [`CacheStyle`](@ref)`(f, args...)` for the function and positional argument types you want to customize.
A strategy based on types can be resolved by the compiler.

| Strategy | Use it when |
| :-- | :-- |
| [`GlobalCache()`](@ref GlobalCache) | Tasks should share results (the default). |
| [`GlobalCache{LRU}()`](@ref GlobalCache) | You want exact least-recently-used eviction. |
| [`TaskLocalCache()`](@ref TaskLocalCache) | Tasks should keep separate caches, reducing contention on shared storage. |
| [`NoCache()`](@ref NoCache) | Computing is cheaper than caching, or results should not be reused. |

For example, give each task its own cache for a recursive computation:

```jldoctest
using Cached
@cached fib(n::Int)::BigInt = n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2);

Cached.CacheStyle(::typeof(fib), ::Int) = TaskLocalCache{LRU}();

fib(10)

# output

55
```

To skip caching floating-point calls to `powers`:

```jldoctest powers
Cached.CacheStyle(::typeof(powers), ::AbstractFloat, ::Int) = NoCache();

powers(2.0; offset = 1.0)

# output

3-element Vector{Float64}:
 3.0
 5.0
 9.0
```

`GlobalCache()` and `TaskLocalCache()` use the [configured container](configuration.md), Clock by default.
See [Eviction policies](eviction.md) for how Clock and LRU choose entries to remove.
[`GlobalLRUCache()`](@ref GlobalLRUCache) is an alias for `GlobalCache{LRU}()`.

Task-local caches live for the task's lifetime and are absent from the global management API and dashboard.
Built-in task-local containers are bounded, but `TaskLocalCache{Dict}()` is unbounded.
Task-local caches can be separate per key and value type; their limits are not a single budget for the whole function.

[`DiskCacheStyle`](@ref) selects disk caching independently.
`NoCache()` as the RAM strategy can still read and fill a disk cache; see [Disk caching](disk.md).

### Inspecting and limiting caches

Global caches are created on first use.
Normally, one cache holds all cached methods and argument types of a function.
If its strategy selects several container types, each gets a separate cache with the function's size limit.

```@example management
using Cached

module MyPackage
    using Cached
    @cached powers(x) = [x^i for i in 1:3]
end

MyPackage.powers(2)
cache_info(MyPackage) # functions owned by this module and submodules
```

Resize a function's cache and inspect it after inserting three keys:

```@example management
set_cache_size!(MyPackage.powers, 2) # count entries
foreach(MyPackage.powers, 1:3)
cache_info(MyPackage.powers)
```

Switch to a byte limit, or clear a module's caches:

```@example management
set_cache_size!(MyPackage.powers, 2^20; by = Cached.cachesize)
MyPackage.powers(2)
empty_caches!(MyPackage) # keep hit/miss counters
cache_info(MyPackage)
```

`cache_info()` and `empty_caches!()` act on all global caches.


Shrinking a cache evicts entries; changing its size measure discards it.
A value larger than the limit is returned but not retained by the built-in containers.
Byte limits measure values, not keys or container overhead, and are not a process-wide memory budget.
See [Configuration](configuration.md) for persistent defaults and custom size measures.

### Keys, results, and invalidation

- Default keys use `hash` and `isequal`, with an additional type check: `f(3)` and `f(3.0)` are different entries.
  Keyword values are included; forwarded keyword order can also distinguish keys.
- Keep keys unchanged while cached.
  Mutating an array used as a key can invalidate its hash.
- RAM results are shared objects.
  Copy a mutable result before changing it.
- Use caching for computations determined by their arguments.
  Changes to external state or method definitions (including through Revise) do not automatically invalidate results.
  Clear the global cache with `empty_caches!`; for disk results, update [`Cached.diskversion`](@ref).
- Built-in shared caches are thread-safe.
  Computations run outside the cache lock, allowing recursion; simultaneous misses may compute the same key more than once.
  Exceptions are propagated without storing a result.

Use [`Cached.cachekey`](@ref) to map equivalent inputs to a common key, or [`Hashed`](@ref) to customize hashing and equality.
See [Custom cache keys](keys.md) for examples and the requirements for sharing results.

## [Why Cached?](@id why-cached)

Cached is for memoization that needs ongoing management: bounded RAM caches, reuse across runs, and tools to inspect and adjust caches while a program runs.
Strategies, settings, persistence, and monitoring work together under one function-level API.

| Package | Choose it when | Tradeoff |
| :--- | :--- | :--- |
| [Memoize.jl](https://github.com/JuliaCollections/Memoize.jl#usage) | You want a small `@memoize` API with a dictionary of your choice. | Limits and statistics depend on the container; persistence, a dashboard, and package settings require additional integration. |
| [Memoization.jl](https://github.com/marius311/Memoization.jl#readme) | You need to memoize individual calls or closures, as well as method definitions. | Its default cache is unbounded and not thread-safe; custom containers can address those needs, but management and persistence tools require additional integration. |
| [LRUCache.jl](https://github.com/JuliaCollections/LRUCache.jl#readme) | You want a thread-safe cache dictionary with limits, statistics, resizing, and eviction callbacks. | You write the function wrapper and management code, or combine it with a memoization macro. |
| Cached.jl | You want bounded caches, per-type strategies, disk persistence, and live monitoring under one API. | The macro requires a method definition; shared caches use locks, and disk results need explicit versioning and cleanup. |

Memoize.jl and Memoization.jl both accept LRUCache.jl containers, so bounded memory and statistics are available without Cached.
Memoization.jl also preserves return-type inference.
For a single in-memory cache, these packages may already cover your needs.

**Key matching:** Memoize.jl and Memoization.jl default to identity-based `IdDict` caches and allow other dictionaries.
Cached defaults to value-based matching with distinct entries for different argument types; [custom keys](keys.md) can merge equivalent inputs.
Hashing large keys can cost more than recomputing.

**Invalidation:** Cached requires manual clearing after code or external state changes.
Memoization.jl handles method redefinition for memoized definitions, though memoized individual calls require clearing; see its [limitations](https://github.com/marius311/Memoization.jl#limitations).
Those limitations also describe thread safety for top-level functions with a thread-safe container, but not closures or callable objects.

Disk caching adds serialization and file I/O, so it suits expensive computations.
Disk storage has no automatic eviction, and RAM limits are per cache rather than process-wide.
See [Disk caching](disk.md) and [Configuration](configuration.md) for these controls.
