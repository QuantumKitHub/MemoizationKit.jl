# An entry of a `ClockCache`; only its reference bit changes after construction.
mutable struct Entry{K, V}
    const hash::UInt # the fields read on a hit come first
    const key::K
    const val::V
    @atomic used::Bool # the reference bit
    const size::Int
    const position::Int # in `ring`
end

struct Tombstone end
const TOMBSTONE = Tombstone()

# The table of entries is an open-addressing hash table with linear probing, at most half full,
# read without the lock. This is safe because:
# 1. entries do not change after construction, apart from their reference bit;
# 2. a published table never changes length, but is replaced as a whole;
# 3. a slot only changes, under the lock, from `nothing` or `TOMBSTONE` to an entry, from an entry
#    to `TOMBSTONE`, or to `nothing` if the next slot is `nothing`. Entries never move, so a probe
#    finds every entry that is present.
# Slots are loaded with acquire and stored with release ordering. Before Julia 1.12, which added
# atomic indexing, `setindex!` into a `Vector{Any}` is a release store with a GC write barrier
# (checked by the tests); storing through a pointer would skip the barrier.
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
mutable struct ClockCache{K, V} <: DictCache{K, V}
    @atomic table::SlotTable
    occupied::Int # slots of `table` holding an entry or a tombstone
    const ring::Vector{Entry{K, V}} # the clock; free positions are unassigned
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
        return new{K, V}(emptytable(), 0, Entry{K, V}[], Int[], 0, 0, 0, maxsize, by, counts, ReentrantLock())
    end
end

function emptytable(n::Int = 16)
    t = SlotTable(undef, n)
    foreach(i -> storeslot!(t, i, nothing), 1:n)
    return t
end

# The slot after `i`, wrapping around (tables have a power-of-two length); a probe for `hash`
# starts at `nextslot(t, hash % Int)`.
nextslot(t::SlotTable, i::Int) = i & (length(t) - 1) + 1

# The entry for the probe `p` (see `Key`), or `nothing`.
findentry(::ClockCache, ::Nothing) = nothing
@inline function findentry(c::ClockCache{K, V}, p::Key{P}) where {K, V, P}
    t = @atomic :acquire c.table
    i = nextslot(t, p.hash % Int)
    for _ in 1:length(t) # bounds the probe also while slots change
        e = loadslot(t, i)
        e === nothing && return nothing
        e isa Entry{K, V} && e.hash == p.hash && e.key isa P && isequal(p.key, e.key::P) && return e
        i = nextslot(t, i)
    end
    return nothing
end

# Sets the reference bit only if it is clear, so hot entries are not written to.
@inline function usevalue!(e::Entry)
    (@atomic :monotonic e.used) || (@atomic :monotonic e.used = true)
    return e.val
end

# Each thread counts in its own cache line (8 `Int`s), since a shared counter would bounce
# between cores on every hit; a power of two of lines avoids a division. Tasks on one thread
# cannot interleave between the load and the store, as neither yields.
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
    if 2 * (c.occupied + 1) > length(c.table) # publish a new table without tombstones
        t = emptytable(max(16, nextpow(2, 4 * (c.count + 1))))
        for i in eachindex(c.ring)
            isassigned(c.ring, i) && placeentry!(t, c.ring[i])
        end
        c.occupied = c.count
        @atomic :release c.table = t
    end
    position = isempty(c.freepositions) ? length(resize!(c.ring, length(c.ring) + 1)) : pop!(c.freepositions)
    e = c.ring[position] = Entry{K, V}(p.hash, p.key, v, false, sz, position)
    placeentry!(c.table, e) === nothing && (c.occupied += 1)
    c.count += 1
    c.currentsize += sz
    return c
end

# Store `e` in the first slot of its probe without an entry, and return what was there.
function placeentry!(t::SlotTable, e::Entry)
    i = nextslot(t, e.hash % Int)
    while (old = loadslot(t, i)) isa Entry
        i = nextslot(t, i)
    end
    storeslot!(t, i, e)
    return old
end

function removeentry!(c::ClockCache, e::Entry)
    t = c.table
    i = nextslot(t, e.hash % Int)
    while loadslot(t, i) !== e
        i = nextslot(t, i)
    end
    if loadslot(t, nextslot(t, i)) === nothing
        # no probe passes this slot or the tombstones before it, so they can all become empty
        while true
            storeslot!(t, i, nothing)
            c.occupied -= 1
            i = nextslot(t, i - 2)
            loadslot(t, i) === TOMBSTONE || break
        end
    else
        storeslot!(t, i, TOMBSTONE)
    end
    Base._unsetindex!(c.ring, e.position) # internal
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
        isassigned(c.ring, c.hand) || continue
        e = c.ring[c.hand]
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

function snapshot(c::ClockCache{K, V}) where {K, V}
    return @lock c.lock Pair{K, V}[c.ring[i].key => c.ring[i].val for i in eachindex(c.ring) if isassigned(c.ring, i)]
end
