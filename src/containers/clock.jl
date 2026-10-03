"""
    ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing)

Cache with CLOCK (second-chance) eviction, an approximation of LRU. A hit only sets the entry's
reference bit; on eviction a hand sweeps the slots, clearing set bits and evicting the first
entry whose bit is already clear. New entries start with a clear bit, so entries that are
never hit again are evicted first.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.
"""
mutable struct ClockCache{K, V} <: SlotCache{K, V}
    const slots::Slots{V}
    const ref::Vector{Bool}
    const live::Vector{Bool}
    hand::Int # last inspected slot
end

ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V} =
    ClockCache{K, V}(Slots{V}(maxsize, by), Bool[], Bool[], 0)

function _admit!(c::ClockCache, i::Int)
    i > length(c.ref) && (push!(c.ref, false); push!(c.live, false))
    c.ref[i] = false
    c.live[i] = true
    return c
end

_touch!(c::ClockCache, i::Int) = (c.ref[i] = true; c)

_forget!(c::ClockCache, i::Int) = (c.live[i] = false; c)

# Terminates within two sweeps, since the first sweep clears every reference bit.
function _victim(c::ClockCache)
    n = length(c.ref)
    while true
        c.hand = c.hand >= n ? 1 : c.hand + 1
        i = c.hand
        c.live[i] || continue
        c.ref[i] || return i
        c.ref[i] = false
    end
    return
end
