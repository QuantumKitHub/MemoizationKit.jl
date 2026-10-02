# Implementing a cache

```@meta
CurrentModule = Cached
```

The containers of Cached, [`LRU`](@ref) and [`ClockCache`](@ref), are subtypes of
[`Cached.AbstractCache`](@ref). They share all storage, locking and size accounting, and
differ only in their eviction policy. A new container implements a policy in four methods,
and can then be used anywhere the built-in ones are, e.g. as `GlobalCache{MyCache}()`.

## What the generic code guarantees

- **Thread safety.** Every operation takes the cache's lock (a `ReentrantLock`), and every policy
  method is called with it held. `get!` releases the lock while it computes a missing value, so
  computations run in parallel and may recurse into the same cache. If two tasks compute the same
  key, the first to finish stores it; an exception stores nothing.
- **Keys that do not box.** Keys are stored as `Key{Any}`, with their hash, and looked up with a
  concretely typed `Key{K}` probe. A hit does not allocate, also in a `C{Any, Any}` cache like
  those of `@cached` functions, and eviction never re-hashes a key. Keys of different types are
  different entries, even when they are `isequal`.
- **Size accounting.** Each entry has a size: 1, or `by(value)` when the cache was made with a
  `by` function. Inserting evicts, through the policy, until the new entry fits in `maxsize`.
  A value larger than `maxsize` is returned but not stored.
- **Slots.** Entries live in numbered slots, reused once freed. The policy only sees slot numbers;
  the keys, values and sizes are in `c.slots` (a [`Cached.Slots`](@ref)), which it may read,
  e.g. `c.slots.sizes[i]` for a size-aware policy.

All of these methods are provided for any subtype:
`get!`, `get`, `getindex`, `setindex!`, `haskey`, `delete!`, `empty!`, `length`, `isempty`,
iteration (over a snapshot taken under the lock, in unspecified order), [`resize!`](@ref
resize!(::Cached.AbstractCache)), [`Cached.cache_stats`](@ref) and `show`, besides everything an
`AbstractDict` derives from these.

## The policy interface

A subtype `C{K, V} <: Cached.AbstractCache{K, V}`

- has a field `slots::Cached.Slots{V}`;
- has a constructor `C{K, V}(; maxsize, by)`, which is how [`GlobalCache`](@ref) and
  [`TaskLocalCache`](@ref) create it;
- tracks its occupied slots through these four methods:

```@docs
Cached.Slots
Cached.admit!
Cached.touch!
Cached.victim
Cached.forget!
```

Every slot passes through `admit!`, any number of `touch!` calls, and then `forget!`, either
from an eviction (after `victim` chose it), a `delete!`, an overwrite or `empty!`.

## Example: first in, first out

A cache that evicts the oldest entry, ignoring hits:

```jldoctest fifo
using Cached

mutable struct FIFO{K, V} <: Cached.AbstractCache{K, V}
    const slots::Cached.Slots{V}
    const queue::Vector{Int} # occupied slots, oldest first
end

FIFO{K, V}(; maxsize = 10_000, by = nothing) where {K, V} =
    FIFO{K, V}(Cached.Slots{V}(maxsize, by), Int[])

Cached.admit!(c::FIFO, i::Int) = push!(c.queue, i)
Cached.touch!(::FIFO, ::Int) = nothing
Cached.victim(c::FIFO) = first(c.queue)
Cached.forget!(c::FIFO, i::Int) = deleteat!(c.queue, findfirst(==(i), c.queue))

c = FIFO{Int, String}(; maxsize = 2)
c[1] = "one"
c[2] = "two"
get!(() -> "uno", c, 1) # a hit, which does not keep 1
c[3] = "three"          # evicts 1, the oldest
sort!(collect(keys(c))), Cached.cache_stats(c)

# output

([2, 3], (hits = 1, misses = 0, length = 2, currentsize = 2, maxsize = 2, by = nothing))
```

`forget!` takes linear time here, which is fine for evictions (the victim is first in the queue)
but not for frequent deletions; [`LRU`](@ref) keeps a doubly linked list in `prev`/`next`
vectors instead. The test suite runs this `FIFO` through the same tests as the built-in caches.

## Other locking schemes

The generic methods take the lock on every lookup. A container that needs a different scheme,
such as lock-free hits for a CLOCK policy, can still use `Slots` and the policy methods for its
bookkeeping, and define its own `get!`, `get`, `getindex` and `haskey` for its type.
