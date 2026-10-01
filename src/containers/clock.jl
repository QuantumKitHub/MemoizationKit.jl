"""
    ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing)

Cache with CLOCK (second-chance) eviction, an approximation of LRU. A hit only sets the entry's
reference bit; on eviction a hand sweeps the slots, clearing set bits and evicting the first
entry whose bit is already clear. New entries start with a clear bit, so entries that are
never hit again are evicted first.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.
"""
mutable struct ClockCache{K, V} <: AbstractCache{K, V}
    const index::Dict{K, Int}
    const keys::Vector{K}
    const vals::Vector{V}
    const sizes::Vector{Int}
    const ref::Vector{Bool}
    const live::Vector{Bool}
    const free::Vector{Int}
    hand::Int # last inspected slot
    currentsize::Int
    maxsize::Int
    const by::Any
    hits::Int
    misses::Int
    const lock::ReentrantLock
end

function ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V}
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    return ClockCache{K, V}(
        Dict{K, Int}(), K[], V[], Int[], Bool[], Bool[], Int[],
        0, 0, maxsize, by, 0, 0, ReentrantLock()
    )
end

_touch!(c::ClockCache, i::Int) = (c.ref[i] = true; c)

function _place!(c::ClockCache, i::Int)
    c.ref[i] = false
    c.live[i] = true
    return c
end

function _newslot!(c::ClockCache, k, v, sz::Int)
    push!(c.keys, k)
    push!(c.vals, v)
    push!(c.sizes, sz)
    push!(c.ref, false)
    push!(c.live, false)
    return length(c.keys)
end

function _remove!(c::ClockCache, i::Int)
    c.live[i] = false
    return _freeslot!(c, i)
end

# Terminates within two sweeps, since the first sweep clears every reference bit.
function _evict_one!(c::ClockCache)
    n = length(c.keys)
    while true
        c.hand = c.hand >= n ? 1 : c.hand + 1
        i = c.hand
        c.live[i] || continue
        if c.ref[i]
            c.ref[i] = false
        else
            return _remove!(c, i)
        end
    end
    return
end

function Base.empty!(c::ClockCache)
    @lock c.lock begin
        foreach(empty!, (c.index, c.keys, c.vals, c.sizes, c.ref, c.live, c.free))
        c.hand = c.currentsize = 0
    end
    return c
end

# Entries in slot order. Call with the lock held.
function _pairs(c::ClockCache{K, V}) where {K, V}
    return Pair{K, V}[c.keys[i] => c.vals[i] for i in eachindex(c.keys) if c.live[i]]
end
