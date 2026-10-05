# Implementing a cache

```@meta
CurrentModule = Cached
```

A [`Cached.AbstractCache`](@ref) is the container behind [`GlobalCache`](@ref) and [`TaskLocalCache`](@ref).
Besides [`LRU`](@ref) and [`ClockCache`](@ref), any subtype `C{K, V} <: Cached.AbstractCache{K, V}` implementing these methods can be used:

| Method | Contract |
| :----- | :------- |
| `C{K, V}(; maxsize, by)` | An empty cache. `maxsize` bounds the number of entries, or the sum of `by(value)` if `by !== nothing`. |
| `get!(default, c, key)` | The value stored for `key`, or else `default()`, stored if it fits. Keys of different types are different entries. |
| `empty!(c)` | Remove all entries, keeping the statistics. |
| [`resize!(c; maxsize)`](@ref resize!(::Cached.AbstractCache)) | Set the size limit, evicting entries until they fit. |
| [`Cached.cache_stats(c)`](@ref) | `(; hits, misses, length, currentsize, maxsize, by)` |

They may be called from any task, so they must be thread-safe, and `get!` must not hold a lock while it calls `default`, which may recurse into the same cache or throw.
`show` is derived from `cache_stats`; the other `AbstractDict` methods are optional.

## Example: first in, first out

```jldoctest fifo
using Cached

mutable struct FIFO{K, V} <: Cached.AbstractCache{K, V}
    const entries::Dict{Any, Tuple{V, Int}} # (typeof(key), key) => (value, size)
    const order::Vector{Any}                # keys of `entries`, oldest first
    const lock::ReentrantLock
    const by::Any
    maxsize::Int
    currentsize::Int
    hits::Int
    misses::Int
end

FIFO{K, V}(; maxsize = 10_000, by = nothing) where {K, V} =
    FIFO{K, V}(Dict{Any, Tuple{V, Int}}(), [], ReentrantLock(), by, maxsize, 0, 0, 0)

function Base.get!(default::Base.Callable, c::FIFO{K, V}, key) where {K, V}
    k = (typeof(key), key)
    @lock c.lock begin
        haskey(c.entries, k) && (c.hits += 1; return c.entries[k][1])
        c.misses += 1
    end
    v = convert(V, default())::V # without the lock
    @lock c.lock begin
        haskey(c.entries, k) && return c.entries[k][1] # stored by another task meanwhile
        sz = c.by === nothing ? 1 : Int(c.by(v))
        c.entries[k] = (v, sz)
        push!(c.order, k)
        c.currentsize += sz
        evict!(c)
    end
    return v
end

function evict!(c::FIFO)
    while c.currentsize > c.maxsize
        c.currentsize -= pop!(c.entries, popfirst!(c.order))[2]
    end
    return c
end

Base.empty!(c::FIFO) = @lock c.lock (empty!(c.entries); empty!(c.order); c.currentsize = 0; c)
Base.resize!(c::FIFO; maxsize::Integer) = @lock c.lock (c.maxsize = maxsize; evict!(c))
Cached.cache_stats(c::FIFO) =
    @lock c.lock (; c.hits, c.misses, length = length(c.entries), c.currentsize, c.maxsize, c.by)

@cached square(x) = x^2
Cached.CacheStyle(::typeof(square), x) = GlobalCache{FIFO}()

square.(1:3); square(3); square(3.0)
set_cache_size!(square, 2) # evicts square(1) and square(2)
square(1)
only(cache_info(square)).second

# output

FIFO{Any, Any}(2/2 entries, 1 hits, 5 misses)
```

`TaskLocalCache{FIFO}()` works the same way.
This `FIFO` boxes its keys, so unlike `LRU` and `ClockCache` its hits allocate.
