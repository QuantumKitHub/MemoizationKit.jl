"""
    LRU{K, V}(; maxsize::Integer = 10_000, by = nothing)

Least-recently-used cache, with the recency list stored as integer `prev`/`next` vectors
instead of heap-allocated nodes. Evicts exactly the least recently used entry.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.
"""
mutable struct LRU{K, V} <: AbstractCache{K, V}
    const index::Dict{Key{Any}, Int}
    const keys::Vector{Key{Any}}
    const vals::Vector{V}
    const sizes::Vector{Int}
    const prev::Vector{Int}
    const next::Vector{Int}
    const free::Vector{Int}
    head::Int # most recently used, 0 if empty
    tail::Int # least recently used, 0 if empty
    currentsize::Int
    maxsize::Int
    const by::Any
    hits::Int
    misses::Int
    const lock::ReentrantLock
end

function LRU{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V}
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    return LRU{K, V}(
        Dict{Key{Any}, Int}(), Key{Any}[], V[], Int[], Int[], Int[], Int[],
        0, 0, 0, maxsize, by, 0, 0, ReentrantLock()
    )
end

function _unlink!(c::LRU, i::Int)
    p, n = c.prev[i], c.next[i]
    p == 0 ? (c.head = n) : (c.next[p] = n)
    n == 0 ? (c.tail = p) : (c.prev[n] = p)
    return c
end

function _place!(c::LRU, i::Int)
    c.prev[i] = 0
    c.next[i] = c.head
    c.head == 0 ? (c.tail = i) : (c.prev[c.head] = i)
    c.head = i
    return c
end

function _touch!(c::LRU, i::Int)
    i == c.head && return c
    _unlink!(c, i)
    return _place!(c, i)
end

function _newslot!(c::LRU, k, v, sz::Int)
    push!(c.keys, k)
    push!(c.vals, v)
    push!(c.sizes, sz)
    push!(c.prev, 0)
    push!(c.next, 0)
    return length(c.keys)
end

function _remove!(c::LRU, i::Int)
    _unlink!(c, i)
    return _freeslot!(c, i)
end

_evict_one!(c::LRU) = _remove!(c, c.tail)

function Base.empty!(c::LRU)
    @lock c.lock begin
        foreach(empty!, (c.index, c.keys, c.vals, c.sizes, c.prev, c.next, c.free))
        c.head = c.tail = c.currentsize = 0
    end
    return c
end

# Entries from most to least recently used. Call with the lock held.
function _pairs(c::LRU{K, V}) where {K, V}
    ps = Vector{Pair{K, V}}(undef, length(c.index))
    i = c.head
    for j in eachindex(ps)
        ps[j] = c.keys[i].key::K => c.vals[i]
        i = c.next[i]
    end
    return ps
end
