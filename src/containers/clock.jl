# An entry of a `ClockCache`; only its reference bit changes after construction. The fields read
# on a hit come first.
mutable struct Entry{K, V}
    const hash::UInt
    const key::K
    const val::V
    @atomic used::Bool # the reference bit
    const size::Int
    const position::Int # in `ring`
end

struct Tombstone end
const TOMBSTONE = Tombstone()

# The table is an open-addressing hash table with linear probing, at most half full, so that
# every probe ends at an empty slot. Readers take no lock, which is safe because of three rules:
#
# 1. Entries do not change after construction, apart from their reference bit, so a reader
#    sees a key together with its own value.
# 2. A published table never changes length: it is replaced as a whole, by a release store to
#    `c.table`, so the indices of a reader stay in bounds.
# 3. Under the lock, a slot only changes from `nothing` to an entry, from an entry to
#    `TOMBSTONE`, or from `TOMBSTONE` to an entry; or to `nothing` when the next slot is
#    `nothing`, so that no probe passes it anyway. Entries never move, so a probe for a key that
#    is present and not concurrently removed always finds it.
#
# Slots are loaded with acquire and stored with release ordering, so a reader sees fully
# constructed entries. On Julia 1.10 and 1.11, which lack atomic indexing, a `Vector{Any}` is
# read through a pointer and written with `setindex!`, which compiles to a release store with a
# GC write barrier there (checked by the tests). Storing through a pointer would skip the
# barrier, and the GC could free the entry.
@static if VERSION >= v"1.12"
    const SlotTable = AtomicMemory{Any}
    loadslot(t::SlotTable, i::Int) = @atomic :acquire t[i]
    storeslot!(t::SlotTable, i::Int, x) = (@atomic :release t[i] = x; t)
else
    const SlotTable = Vector{Any}
    loadslot(t::SlotTable, i::Int) = GC.@preserve t unsafe_load(pointer(t, i), :acquire)
    storeslot!(t::SlotTable, i::Int, x) = (t[i] = x; t)
end

"""
    ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing)

Cache with CLOCK (second-chance) eviction, an approximation of LRU. A hit only sets the entry's
reference bit; on eviction a hand sweeps the slots, clearing set bits and evicting the first
entry whose bit is already clear. New entries start with a clear bit, so entries that are
never hit again are evicted first.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.

Lookups take no lock and write no shared memory, so hits scale with the number of threads that
share the cache. Insertions, evictions and the other changes take a lock. A lookup that races
with a removal may still return the removed value, and one that races with an insertion may
miss it; a returned value always belongs to its key.
"""
mutable struct ClockCache{K, V} <: AbstractCache{K, V}
    @atomic table::SlotTable # entries, read without the lock
    occupied::Int # slots of `table` holding an entry or a tombstone
    const ring::Vector{Union{Nothing, Entry{K, V}}} # the clock, `nothing` for a free position
    const freepositions::Vector{Int}
    hand::Int # last inspected position of `ring`
    count::Int
    currentsize::Int
    maxsize::Int
    const by::Any
    const counts::Vector{Int} # hits and misses per thread, see `countlookup!`
    const lock::ReentrantLock

    function ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V}
        maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
        counts = zeros(Int, 8 * nextpow(2, Threads.maxthreadid()))
        return new{K, V}(emptytable(), 0, Union{Nothing, Entry{K, V}}[], Int[], 0, 0, 0, maxsize, by, counts, ReentrantLock())
    end
end

function emptytable(n::Int = 16)
    t = SlotTable(undef, n)
    foreach(i -> storeslot!(t, i, nothing), 1:n)
    return t
end

# Slot indices run from 1 to `length(t)`, a power of two; the probe for `hash` starts at
# `(hash % Int) & mask + 1`, and moves on with `i & mask + 1`, wrapping around at the end.

# The entry of the probe `p` (see `Key`), or `nothing`.
findentry(::ClockCache, ::Nothing) = nothing
@inline function findentry(c::ClockCache{K, V}, p::Key{P}) where {K, V, P}
    t = @atomic :acquire c.table
    mask = length(t) - 1
    i = (p.hash % Int) & mask + 1
    for _ in 0:mask # bounds the probe also while slots change
        e = loadslot(t, i)
        e === nothing && return nothing
        e isa Entry{K, V} && e.hash == p.hash && e.key isa P && isequal(p.key, e.key::P) && return e
        i = i & mask + 1
    end
    return nothing
end

# A hit sets the reference bit only if it is clear, so hot entries are not written to at all.
@inline function usevalue!(e::Entry)
    (@atomic :monotonic e.used) || (@atomic :monotonic e.used = true)
    return e.val
end

# Hits and misses are counted per thread, a cache line (8 `Int`s) apart, since a shared counter
# would bounce between cores on every hit. There is a power of two of such lines, so a thread
# finds its own without a division. Two tasks on one thread cannot interleave between the load
# and the store, since neither yields; threads adopted after the cache was created share
# counters, and may then lose a few counts.
@enum LookupOutcome HIT = 1 MISS = 2
@inline function countlookup!(c::ClockCache, outcome::LookupOutcome)
    counts = c.counts
    i = 8 * ((Threads.threadid() - 1) & (length(counts) ÷ 8 - 1)) + Int(outcome)
    GC.@preserve counts begin
        p = pointer(counts, i)
        unsafe_store!(p, unsafe_load(p, :monotonic) + 1, :monotonic)
    end
    return nothing
end

function Base.get!(default::F, c::ClockCache{K, V}, key) where {F <: Base.Callable, K, V}
    probe = _newkey(c, key)
    e = findentry(c, probe)
    if e !== nothing
        countlookup!(c, HIT)
        return usevalue!(e)
    end
    countlookup!(c, MISS)
    v = convert(V, default())::V
    sz = _entrysize(c, v)
    @lock c.lock begin
        # another task may have filled the key while we were computing
        e = findentry(c, probe)
        e === nothing || return e.val
        addentry!(c, probe, v, sz)
    end
    return v
end

function Base.get(c::ClockCache, key, default)
    e = findentry(c, _probe(c, key))
    return e === nothing ? default : usevalue!(e)
end
function Base.getindex(c::ClockCache, key)
    e = findentry(c, _probe(c, key))
    e === nothing && throw(KeyError(key))
    return usevalue!(e)
end
Base.haskey(c::ClockCache, key) = findentry(c, _probe(c, key)) !== nothing
Base.length(c::ClockCache) = @lock c.lock c.count
Base.isempty(c::ClockCache) = length(c) == 0

# The mutations below are called with the lock held.

# Insert a key that is not present, evicting until it fits; a value larger than the whole cache
# is not stored.
function addentry!(c::ClockCache{K, V}, p::Key, v, sz::Int) where {K, V}
    sz > c.maxsize && return c
    while c.currentsize + sz > c.maxsize && c.count > 0
        evict!(c)
    end
    if 2 * (c.occupied + 1) > length(c.table)
        # publish a new table without tombstones, at most a quarter full
        t = emptytable(max(16, nextpow(2, 4 * (c.count + 1))))
        foreach(e -> e === nothing || placeentry!(t, e), c.ring)
        c.occupied = c.count
        @atomic :release c.table = t
    end
    position = isempty(c.freepositions) ? length(push!(c.ring, nothing)) : pop!(c.freepositions)
    e = Entry{K, V}(p.hash, p.key, v, false, sz, position)
    c.ring[position] = e
    placeentry!(c.table, e) === nothing && (c.occupied += 1)
    c.count += 1
    c.currentsize += sz
    return c
end

# Store `e` in the first slot of its probe without an entry, and return what was there.
function placeentry!(t::SlotTable, e::Entry)
    mask = length(t) - 1
    i = (e.hash % Int) & mask + 1
    while (old = loadslot(t, i)) isa Entry
        i = i & mask + 1
    end
    storeslot!(t, i, e)
    return old
end

function removeentry!(c::ClockCache, e::Entry)
    t = c.table
    mask = length(t) - 1
    i = (e.hash % Int) & mask + 1
    while loadslot(t, i) !== e
        i = i & mask + 1
    end
    if loadslot(t, i & mask + 1) === nothing
        # No probe continues past the next slot, so this slot and the tombstones before it can
        # end probes as well: they become empty, which saves rebuilding the table.
        while true
            storeslot!(t, i, nothing)
            c.occupied -= 1
            i = (i - 2) & mask + 1
            loadslot(t, i) === TOMBSTONE || break
        end
    else
        storeslot!(t, i, TOMBSTONE)
    end
    c.ring[e.position] = nothing
    push!(c.freepositions, e.position)
    c.count -= 1
    c.currentsize -= e.size
    return c
end

# The hand clears set reference bits until it finds a clear one. Readers may set bits again
# meanwhile, so after two sweeps the hand evicts the next entry anyway. Requires `c.count > 0`.
function evict!(c::ClockCache)
    n = length(c.ring)
    steps = 0
    while true
        c.hand = c.hand >= n ? 1 : c.hand + 1
        steps += 1
        e = c.ring[c.hand]
        e === nothing && continue
        (steps > 2n || !(@atomic :monotonic e.used)) && return removeentry!(c, e)
        @atomic :monotonic e.used = false
    end
    return
end

function Base.setindex!(c::ClockCache{K, V}, v, key) where {K, V}
    probe = _newkey(c, key)
    val = convert(V, v)::V
    sz = _entrysize(c, val)
    @lock c.lock begin
        e = findentry(c, probe)
        e === nothing || removeentry!(c, e)
        addentry!(c, probe, val, sz)
    end
    return c
end

function Base.delete!(c::ClockCache, key)
    @lock c.lock begin
        e = findentry(c, _probe(c, key))
        e === nothing || removeentry!(c, e)
    end
    return c
end

function Base.resize!(c::ClockCache; maxsize::Integer)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    @lock c.lock begin
        c.maxsize = maxsize
        while c.currentsize > c.maxsize && c.count > 0
            evict!(c)
        end
    end
    return c
end

function Base.empty!(c::ClockCache)
    @lock c.lock begin
        @atomic :release c.table = emptytable()
        empty!(c.ring)
        empty!(c.freepositions)
        c.occupied = c.hand = c.count = c.currentsize = 0
    end
    return c
end

function cache_stats(c::ClockCache)
    counts = c.counts
    total(outcome) = GC.@preserve counts sum(i -> unsafe_load(pointer(counts, i), :monotonic), Int(outcome):8:length(counts))
    return @lock c.lock (; hits = total(HIT), misses = total(MISS), length = c.count, c.currentsize, c.maxsize, c.by)
end

# Iteration walks a snapshot copied under the lock, in insertion order, like that of `SlotCache`.
Base.IteratorSize(::Type{<:ClockCache}) = Base.SizeUnknown()
function Base.iterate(c::ClockCache{K, V}) where {K, V}
    snapshot = @lock c.lock Pair{K, V}[e.key => e.val for e in c.ring if e !== nothing]
    return iterate(c, (snapshot, 1))
end
function Base.iterate(::ClockCache, (snapshot, i)::Tuple{Vector, Int})
    return i > length(snapshot) ? nothing : (snapshot[i], (snapshot, i + 1))
end

# The entries below the compact header.
Base.show(io::IO, m::MIME"text/plain", c::ClockCache) = invoke(show, Tuple{IO, MIME"text/plain", AbstractDict}, io, m, c)
