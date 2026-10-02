"""
    LRU{K, V}(; maxsize::Integer = 10_000, by = nothing)

Least-recently-used cache, with the recency list stored as integer `prev`/`next` vectors
instead of heap-allocated nodes. Evicts exactly the least recently used entry.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.
"""
mutable struct LRU{K, V} <: AbstractCache{K, V}
    const slots::Slots{V}
    const prev::Vector{Int}
    const next::Vector{Int}
    head::Int # most recently used, 0 if empty
    tail::Int # least recently used, 0 if empty
end

LRU{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V} =
    LRU{K, V}(Slots{V}(maxsize, by), Int[], Int[], 0, 0)

function admit!(c::LRU, i::Int)
    i > length(c.prev) && (push!(c.prev, 0); push!(c.next, 0))
    c.prev[i] = 0
    c.next[i] = c.head
    c.head == 0 ? (c.tail = i) : (c.prev[c.head] = i)
    c.head = i
    return c
end

function forget!(c::LRU, i::Int)
    p, n = c.prev[i], c.next[i]
    p == 0 ? (c.head = n) : (c.next[p] = n)
    n == 0 ? (c.tail = p) : (c.prev[n] = p)
    return c
end

touch!(c::LRU, i::Int) = i == c.head ? c : admit!(forget!(c, i), i)

victim(c::LRU) = c.tail
