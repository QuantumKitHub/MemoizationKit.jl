# `ClockCache` for a single task, where lock-free hits gain nothing: every operation takes the
# (uncontended) lock, hits and misses are plain counters, and the slots live in vectors indexed
# by a `Dict` (see `AbstractCache`). `TaskLocalCache{ClockCache}` uses it, see `_localtype`;
# it evicts in the same order as `ClockCache`.
mutable struct LocalClockCache{K, V} <: AbstractCache{K, V}
    const index::Dict{Key{Any}, Int}
    const keys::Vector{Key{Any}}
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

function LocalClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V}
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    return LocalClockCache{K, V}(
        Dict{Key{Any}, Int}(), Key{Any}[], V[], Int[], Bool[], Bool[], Int[],
        0, 0, maxsize, by, 0, 0, ReentrantLock()
    )
end

_touch!(c::LocalClockCache, i::Int) = (c.ref[i] = true; c)

function _place!(c::LocalClockCache, i::Int)
    c.ref[i] = false
    c.live[i] = true
    return c
end

function _newslot!(c::LocalClockCache, k, v, sz::Int)
    push!(c.keys, k)
    push!(c.vals, v)
    push!(c.sizes, sz)
    push!(c.ref, false)
    push!(c.live, false)
    return length(c.keys)
end

function _remove!(c::LocalClockCache, i::Int)
    c.live[i] = false
    return _freeslot!(c, i)
end

# Terminates within two sweeps, since the first sweep clears every reference bit.
function _evict_one!(c::LocalClockCache)
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

function Base.empty!(c::LocalClockCache)
    @lock c.lock begin
        foreach(empty!, (c.index, c.keys, c.vals, c.sizes, c.ref, c.live, c.free))
        c.hand = c.currentsize = 0
    end
    return c
end

# Entries in slot order. Call with the lock held.
function _pairs(c::LocalClockCache{K, V}) where {K, V}
    return Pair{K, V}[c.keys[i].key::K => c.vals[i] for i in eachindex(c.keys) if c.live[i]]
end
