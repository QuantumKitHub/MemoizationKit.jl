# Usage

```@meta
CurrentModule = Cached
```

## Memoizing a method

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

## Choosing a strategy

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

```julia
Cached.CacheStyle(::typeof(powers), ::AbstractFloat, ::Int) = NoCache()
```

`GlobalCache()` and `TaskLocalCache()` use the [configured container](configuration.md), Clock by default.
Clock gives recently used entries a second chance during eviction; LRU evicts the least recently used entry.
[`GlobalLRUCache()`](@ref GlobalLRUCache) is an alias for `GlobalCache{LRU}()`.

Task-local caches live for the task's lifetime and are absent from the global management API and dashboard.
Built-in task-local containers are bounded, but `TaskLocalCache{Dict}()` is unbounded.
Task-local caches can be separate per key and value type; their limits are not a single budget for the whole function.

[`DiskCacheStyle`](@ref) selects disk caching independently.
`NoCache()` as the RAM strategy can still read and fill a disk cache; see [Disk caching](disk.md).

## Inspecting and limiting caches

Global caches are created on first use.
Normally, one cache holds all cached methods and argument types of a function.
If its strategy selects several container types, each gets a separate cache with the function's size limit.

```julia
cache_info(powers)                             # live f => cache pairs, with size and statistics
cache_info(MyPackage)                          # functions owned by this module and submodules
cache_info()                                   # all global caches
set_cache_size!(powers, 1000)                   # count entries
set_cache_size!(powers, 2^20; by = Cached.cachesize) # measure values in bytes
empty_caches!(powers)                          # clear entries, keep hit/miss counters
empty_caches!(MyPackage)                       # clear the package's global caches
```

Shrinking a cache evicts entries; changing its size measure discards it.
A value larger than the limit is returned but not retained by the built-in containers.
Byte limits measure values, not keys or container overhead, and are not a process-wide memory budget.
See [Configuration](configuration.md) for persistent defaults and custom size measures.

## Keys, results, and invalidation

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

## How it works

The macro moves the body to [`Cached.implementation`](@ref) and leaves the original method as a wrapper.
Strategy dispatch, lookup, and computation use ordinary Julia code; the call path defines no methods at runtime.
Caches are created lazily, so definitions work in precompiled packages.
To supply a different container, see [Implementing a cache](interface.md).
