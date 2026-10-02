# An entry of a `ClockCache`; see the rules below it.
mutable struct Entry{V}
    const key::Any
    const hash::UInt
    const val::V
    const size::Int
    @atomic ref::Bool
    const pos::Int # slot in `ring`
end

struct Tombstone end
const TOMBSTONE = Tombstone()

"""
    ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing)

Cache with CLOCK (second-chance) eviction, an approximation of LRU. A hit only sets the entry's
reference bit; on eviction a hand sweeps the slots, clearing set bits and evicting the first
entry whose bit is already clear. New entries start with a clear bit, so entries that are
never hit again are evicted first.

`maxsize` limits the number of entries, or, when `by` is given, the sum of `by(value)` over
all entries.

Hits take no lock, and write to the entry only to set a clear reference bit, so a cache
shared between threads scales with the number of threads on hits. Misses, insertions,
evictions and every other mutation take the lock. A lookup that races with a removal
(eviction, `delete!` or `empty!`) may still return the removed entry, and one that races with
an insertion may miss it; the returned value always belongs to its key.
"""
mutable struct ClockCache{K, V} <: AbstractCache{K, V}
    @atomic table::Vector{Any} # open-addressing hash table of `Entry{V}`s, see `_find`
    used::Int # entries and tombstones in `table`
    const ring::Vector{Union{Nothing, Entry{V}}} # the clock, with `nothing` for a free slot
    const free::Vector{Int} # free slots of `ring`
    hand::Int # last inspected slot of `ring`
    count::Int
    currentsize::Int
    maxsize::Int
    const by::Any
    const counts::Vector{Int} # hits and misses per thread, see `_count!`
    const lock::ReentrantLock
end

# Lock-free reads rest on three rules, which every method below keeps:
#
# 1. An `Entry` is immutable apart from its reference bit, so a reader that loads one sees a key
#    with its own value.
# 2. A table is never resized: it is replaced as a whole by a new one, published with a release
#    store to `c.table`. Readers load the table and then each slot with acquire ordering, so
#    they see fully constructed entries, and their indices are always in bounds.
# 3. In a published table, a slot only changes from `nothing` to an entry, from an entry to
#    `TOMBSTONE`, or from `TOMBSTONE` to an entry, all under the lock; or to `nothing` when the
#    next slot is `nothing`, so that no probe passes it anyway. Entries never move, so a probe
#    for a key that is present and not concurrently removed always finds it.
#
# Writers store slots with `setindex!`, which is a release store with a GC write barrier on every
# supported Julia version. (Storing through a pointer would skip the barrier, and the GC could
# free the entry.) Removed entries are dropped from the table rather than unset, so readers
# never see an undefined slot, and the GC collects them once no reader holds them.

const MINTABLE = 16
_emptytable(n::Int = MINTABLE) = fill!(Vector{Any}(undef, n), nothing)

function ClockCache{K, V}(; maxsize::Integer = 10_000, by = nothing) where {K, V}
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    return ClockCache{K, V}(
        _emptytable(), 0, Union{Nothing, Entry{V}}[], Int[], 0, 0, 0, maxsize, by,
        zeros(Int, COUNTSTRIDE * Threads.maxthreadid()), ReentrantLock()
    )
end

@inline function _loadslot(t::Vector{Any}, i::Int)
    return GC.@preserve t unsafe_load(pointer(t, i), :acquire)
end

# The entry for the probe `p` in table `t`, or `nothing`. Linear probing from the hash; a
# table is at most half full, so the probe ends at an empty slot.
@inline function _find(t::Vector{Any}, p::Key{K}, ::Type{V}) where {K, V}
    mask = length(t) - 1
    i = p.hash % Int
    for _ in 0:mask # bounds the loop also if the table is changed while probing
        e = _loadslot(t, (i & mask) + 1)
        e === nothing && return nothing
        if e isa Entry{V} && e.hash == p.hash
            k = e.key
            k isa K && isequal(p.key, k::K) && return e
        end
        i += 1
    end
    return nothing
end
_find(c::ClockCache{K, V}, p::Key) where {K, V} = _find((@atomic :acquire c.table), p, V)

# Hits and misses are counted per thread, in separate cache lines, with relaxed loads and stores:
# a shared counter would bounce between cores on every hit. Two tasks on one thread cannot
# interleave between the load and the store, since neither yields; threads adopted after the
# cache was created share counters, which may then lose a few counts.
const COUNTSTRIDE = 8 # 64 bytes
@inline function _count!(c::ClockCache, which::Int)
    v = c.counts
    i = mod(Threads.threadid() - 1, length(v) ÷ COUNTSTRIDE) * COUNTSTRIDE + which
    GC.@preserve v begin
        p = pointer(v, i)
        unsafe_store!(p, unsafe_load(p, :monotonic) + 1, :monotonic)
    end
    return nothing
end
function _counted(c::ClockCache, which::Int)
    v = c.counts
    return GC.@preserve v sum(i -> unsafe_load(pointer(v, i), :monotonic), which:COUNTSTRIDE:length(v))
end

# Hits only write the reference bit if it is clear, so hot entries are not written at all.
@inline _touch!(e::Entry) = ((@atomic :monotonic e.ref) || (@atomic :monotonic e.ref = true); e)

function _get!(default::F, c::ClockCache{K, V}, p::Key) where {F, K, V}
    e = _find(c, p)
    if e !== nothing
        _count!(c, 1)
        return _touch!(e).val
    end
    _count!(c, 2)
    v = convert(V, default())::V
    sz = _entrysize(c, v)
    @lock c.lock begin
        # another task may have filled the key while we were computing
        e = _find(c, p)
        e === nothing || return e.val
        _insert!(c, p, v, sz)
    end
    return v
end

_lookup(c::ClockCache, key) = (p = _probe(c, key); p === nothing ? nothing : _find(c, p))

function Base.get(c::ClockCache, key, default)
    e = _lookup(c, key)
    return e === nothing ? default : _touch!(e).val
end
function Base.getindex(c::ClockCache, key)
    e = _lookup(c, key)
    e === nothing && throw(KeyError(key))
    return _touch!(e).val
end
Base.haskey(c::ClockCache, key) = _lookup(c, key) !== nothing
Base.length(c::ClockCache) = @lock c.lock c.count
Base.isempty(c::ClockCache) = length(c) == 0

# Mutations, all with the lock held.

function _insert!(c::ClockCache{K, V}, p::Key, v, sz::Int) where {K, V}
    sz > c.maxsize && return c
    while c.currentsize + sz > c.maxsize && c.count > 0
        _evict_one!(c)
    end
    2 * (c.used + 1) > length(c.table) && _rebuild!(c, c.count + 1)
    isempty(c.free) && push!(c.ring, nothing)
    pos = isempty(c.free) ? length(c.ring) : pop!(c.free)
    e = Entry{V}(p.key, p.hash, v, sz, false, pos)
    c.ring[pos] = e
    _place!(c.table, e) === nothing && (c.used += 1)
    c.count += 1
    c.currentsize += sz
    return c
end

# Store `e` in the first free slot of its probe sequence; returns what was there.
function _place!(t::Vector{Any}, e::Entry)
    mask = length(t) - 1
    i = e.hash % Int
    while true
        j = (i & mask) + 1
        old = t[j]
        if !(old isa Entry)
            t[j] = e
            return old
        end
        i += 1
    end
    return
end

# Replace the table by one without tombstones, with room for `n` entries at half load or less.
function _rebuild!(c::ClockCache, n::Int)
    t = _emptytable(max(MINTABLE, nextpow(2, 4n)))
    for e in c.ring
        e === nothing || _place!(t, e)
    end
    c.used = c.count
    @atomic :release c.table = t
    return c
end

function _remove!(c::ClockCache, e::Entry)
    t = c.table
    mask = length(t) - 1
    i = e.hash % Int
    while t[(i & mask) + 1] !== e
        i += 1
    end
    if t[((i + 1) & mask) + 1] === nothing
        # No probe continues past the next slot, so this slot, and the tombstones before it,
        # can end probes as well: they become empty, which saves rebuilds.
        while true
            t[(i & mask) + 1] = nothing
            c.used -= 1
            i -= 1
            t[(i & mask) + 1] === TOMBSTONE || break
        end
    else
        t[(i & mask) + 1] = TOMBSTONE
    end
    c.ring[e.pos] = nothing
    push!(c.free, e.pos)
    c.count -= 1
    c.currentsize -= e.size
    return c
end

# Readers may set reference bits while the hand clears them, so after two sweeps without
# finding a clear bit the entry under the hand is evicted anyway.
function _evict_one!(c::ClockCache)
    n = length(c.ring)
    for sweep in 1:(2n + 1)
        c.hand = c.hand >= n ? 1 : c.hand + 1
        e = c.ring[c.hand]
        e === nothing && continue
        if sweep <= 2n && (@atomic :monotonic e.ref)
            @atomic :monotonic e.ref = false
        else
            return _remove!(c, e)
        end
    end
    error("unreachable: no entry to evict")
end

function Base.setindex!(c::ClockCache{K, V}, v, key) where {K, V}
    p = _newkey(c, key)
    val = convert(V, v)::V
    sz = _entrysize(c, val)
    @lock c.lock begin
        e = _find(c, p)
        e === nothing || _remove!(c, e)
        _insert!(c, p, val, sz)
    end
    return c
end

function Base.delete!(c::ClockCache, key)
    @lock c.lock begin
        e = _lookup(c, key)
        e === nothing || _remove!(c, e)
    end
    return c
end

function Base.resize!(c::ClockCache; maxsize::Integer)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    @lock c.lock begin
        c.maxsize = maxsize
        while c.currentsize > c.maxsize && c.count > 0
            _evict_one!(c)
        end
    end
    return c
end

function Base.empty!(c::ClockCache)
    @lock c.lock begin
        @atomic :release c.table = _emptytable()
        empty!(c.ring)
        empty!(c.free)
        c.used = c.hand = c.count = c.currentsize = 0
    end
    return c
end

function cache_stats(c::ClockCache)
    return @lock c.lock (;
        hits = _counted(c, 1), misses = _counted(c, 2), length = c.count, c.currentsize, c.maxsize,
    )
end

# Entries in slot order. Call with the lock held.
function _pairs(c::ClockCache{K, V}) where {K, V}
    return Pair{K, V}[e.key::K => e.val for e in c.ring if e isa Entry{V}]
end
