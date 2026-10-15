# `ClockCache` for a single task, where lock-free hits gain nothing: every operation takes the
# (uncontended) lock, and the hit and miss counters are plain fields. `TaskLocalCache{ClockCache}`
# uses it, see `_localtype`; it evicts in the same order as `ClockCache`.
mutable struct LocalClockCache{K, V} <: SlotCache{K, V}
    const slots::Slots{V}
    const ref::Vector{Bool}
    const live::Vector{Bool}
    hand::Int # last inspected slot
end

LocalClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V} =
    LocalClockCache{K, V}(Slots{V}(maxsize, by), Bool[], Bool[], 0)

function admit!(c::LocalClockCache, i::Int)
    i > length(c.ref) && (push!(c.ref, false); push!(c.live, false))
    c.ref[i] = false
    c.live[i] = true
    return c
end

touch!(c::LocalClockCache, i::Int) = (c.ref[i] = true; c)

forget!(c::LocalClockCache, i::Int) = (c.live[i] = false; c)

# Terminates within two sweeps, since the first sweep clears every reference bit.
function victim(c::LocalClockCache)
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
