# Custom cache keys

```@meta
CurrentModule = MemoizationKit
```

A computation may depend on only part of its input: an array's shape, a tensor space's sector structure, or a normalized name.
Specialize [`MemoizationKit.cachekey`](@ref) to let equivalent inputs share a cached result.
The function body, return-type inference, [`CacheStyle`](@ref), and [`DiskCacheStyle`](@ref) still use the original arguments.

## The default key

Without an overload, the key contains every positional argument and, when present, the keyword `NamedTuple`:

```jldoctest
using MemoizationKit

(MemoizationKit.cachekey(identity, 1, 2), MemoizationKit.cachekey(identity, 1, 2; scale = 3))

# output

((1, 2), (1, 2, (scale = 3,)))
```

The cached method fills in default positional and keyword values before calling the hook.
Its overload must accept the resulting arguments, including keywords.
The function itself is the first argument, so each function can define its own mapping.

## Returning a canonical key

A canonical key contains the properties that determine the result.
This example computes the same allocation shape for any input of a given length:

```jldoctest canonical-key
using MemoizationKit

@cached allocation_shape(x; copies = 1) = (length(x), copies)
MemoizationKit.cachekey(::typeof(allocation_shape), x; copies = 1) = (length(x), copies)

a = allocation_shape([1, 2])
b = allocation_shape((3, 4))
(a, b, length(only(cache_info(allocation_shape)).second))

# output

((2, 1), (2, 1), 1)
```

The vector and tuple share an entry because both calls produce the key `(2, 1)`.
MemoizationKit does not retain the original argument types alongside a custom key.
Keywords that affect the result belong in the key too:

```jldoctest canonical-key
allocation_shape([5, 6]; copies = 2)
length(only(cache_info(allocation_shape)).second)

# output

2
```

An overload can also combine positional defaults, varargs, and arbitrary keywords.
Accept them as an ordinary Julia function would and return a key containing the relevant values.
Returning a compact tuple is often sufficient; no wrapper is required.

## Sharing across methods

The same mapping can serve several cached methods of one function:

```jldoctest shared-methods
using MemoizationKit

computations = Ref(0)

@cached function nitems(x::AbstractVector)
    computations[] += 1
    return length(x)
end
@cached function nitems(x::Tuple)
    computations[] += 1
    return length(x)
end
MemoizationKit.cachekey(::typeof(nitems), x) = length(x)

a = nitems([1, 2])
b = nitems((3, 4))
(a, b, computations[])

# output

(2, 2, 1)
```

Only the first method body runs.
All calls merged by a key must accept the same cached result, including its type.
For example, methods returning `Vector{Int}` and `Vector{Float64}` should use separate keys if callers require those types.
Include `typeof(x)` in a custom key when the original input type matters.

[`LRU`](@ref) and [`ClockCache`](@ref) distinguish key types, so use a common key type for calls that should share an entry.
They also need to select the same cache container.
Task-local caches share only within a task; typed dictionaries such as `TaskLocalCache{Dict}()` have separate containers for each key and inferred value type.

## Custom hashing and equality with `Hashed`

When forming a canonical representation is expensive, [`Hashed`](@ref) keeps the original value and supplies the comparison functions instead.
The hash callable takes `(value, seed::UInt)`; the equality callable takes two wrapped values and returns a `Bool`.

```jldoctest hashed-key
using MemoizationKit

lengthhash(x, seed::UInt) = hash(length(x), seed)
lengthequal(x, y) = isequal(length(x), length(y))

@cached wrapped_shape(x; copies = 1) = (length(x), copies)
MemoizationKit.cachekey(::typeof(wrapped_shape), x; copies = 1) =
    (Hashed(x, lengthhash, lengthequal), copies)

a = wrapped_shape([1, 2])
b = wrapped_shape([3, 4])
(a, b, length(only(cache_info(wrapped_shape)).second))

# output

((2, 1), (2, 1), 1)
```

Length is cheap to compute, so a canonical key is simpler here.
For a more complex structure, custom hashing and equality can inspect the relevant fields directly without constructing a separate representation.
The implementation continues to receive `x` itself.

`Hashed` also works as a key in ordinary dictionaries, and `parent` retrieves its value:

```jldoctest hashed-key
a = Hashed([1, 2], lengthhash, lengthequal)
b = Hashed([3, 4], lengthhash, lengthequal)
d = Dict(a => "two items")
(parent(a), isequal(a, b), d[b])

# output

([1, 2], true, "two items")
```

`Hashed(x)` uses `Base.hash` and `Base.isequal`; `Hashed(x, hashf)` changes only hashing.
The callables can be functions, closures, or callable structs.
Two wrappers compare equal only when both callables are identical under `===`.
Closures with different captured settings therefore remain separate even if they have the same function type.

The wrapper's type includes the wrapped value type.
Consequently, wrappers around a vector and a tuple do not share an entry in MemoizationKit's RAM containers.
Return a canonical key of a common type when sharing across those inputs is needed.

## Choosing valid equality

The equality function must be reflexive, symmetric, and transitive.
Whenever it considers two values equal, their hash functions must produce equal hashes for every seed.
Hash collisions between unequal values are fine: the cache still checks equality.

Approximate comparisons such as `isapprox` generally are not transitive.
For tolerance-based grouping, define explicit buckets and use the bucket identifier as the canonical key instead.

Keep every property used by hashing or equality stable while its key is stored.
A `Hashed` wrapper retains its input rather than copying it, so mutating relevant fields can invalidate the cache's lookup assumptions.
A canonical key made from immutable properties avoids that dependency.
MemoizationKit results themselves are shared objects; mutations of a cached result are visible to other callers sharing its key.

## RAM and disk caching

The same key hook feeds both cache levels, but they match entries differently:

| Key choice | RAM matching | Disk matching |
| :--------- | :----------- | :------------ |
| Canonical value | Key type, `hash`, and `isequal` | Serialized key bytes |
| `Hashed` wrapper | Wrapper type, custom hash, and custom equality with matching policies | Serialized wrapper, including its value and callables |

Custom equality alone does not merge disk entries.
To share them, return a canonical key that serializes to the same bytes for equivalent inputs.
Disk caching still needs SQLite.jl and a [`DiskCacheStyle`](@ref) overload; see [Disk caching](disk.md).

After changing a key mapping, call [`empty_caches!`](@ref) for the function.
If it uses disk caching, also change [`MemoizationKit.diskversion`](@ref) or empty its disk cache so entries created under the previous mapping are no longer used.
[`uncached`](@ref) bypasses the key hook and all caches; with positional defaults, supply the full arguments to the implementation.
