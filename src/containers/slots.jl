# Keys are stored as `Key{Any}`, together with their hash, so that eviction never re-hashes them.
# Lookups probe the index with a `Key{K}` of the key's concrete type: comparing it with a stored
# key checks the type first, so the comparison is static and the key is never boxed, also when
# the cache has an abstract key type (as the caches of `@cached` functions do). A probe cannot
# be a `Key{Any}` itself: storing the key in an `Any` field would box it.
struct Key{K}
    key::K
    hash::UInt
end
Key(k) = Key(k, hash(k))
Base.hash(k::Key, h::UInt) = hash(k.hash, h)
Base.isequal(p::Key{K}, s::Key{Any}) where {K} = p.hash == s.hash && s.key isa K && isequal(p.key, s.key::K)
Base.isequal(a::Key{Any}, b::Key{Any}) = a.hash == b.hash && typeof(a.key) === typeof(b.key) && isequal(a.key, b.key)

# The shared implementation of `LRU` and `ClockCache`: every method of a dict-like
# `AbstractCache`, on the storage in the field `slots::Slots{V}`. The subtypes are eviction
# policies over slot numbers, through the hooks below, which are called with the lock held.
abstract type SlotCache{K, V} <: AbstractCache{K, V} end

# The entries in numbered slots (reused once freed), the key index, the size accounting, the
# statistics and the lock.
mutable struct Slots{V}
    const index::Dict{Key{Any}, Int}
    const keys::Vector{Key{Any}}
    const vals::Vector{V}
    const sizes::Vector{Int}
    const free::Vector{Int}
    currentsize::Int
    maxsize::Int
    const by::Any
    hits::Int
    misses::Int
    const lock::ReentrantLock
end

function Slots{V}(maxsize::Integer, by) where {V}
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    return Slots{V}(Dict{Key{Any}, Int}(), Key{Any}[], V[], Int[], Int[], 0, maxsize, by, 0, 0, ReentrantLock())
end

# Each slot passes through `admit!`, any number of `touch!` calls, then `forget!` (on eviction,
# `delete!`, overwrite or `empty!`).
# - `admit!(c, i)`: track the entry just stored in slot `i`; a never-used slot is one past the
#   highest so far, so grow the per-slot metadata.
# - `touch!(c, i)`: a hit on slot `i`; runs on every hit, so keep it cheap.
# - `victim(c)`: the occupied slot to evict (`c` is not empty), then passed to `forget!`.
# - `forget!(c, i)`: stop tracking slot `i`, which is freed afterwards.
function admit! end
function touch! end
function victim end
function forget! end

# The probe for a key that is inserted: converted to `K`, which throws if that is not possible.
_newkey(::SlotCache{K}, key) where {K} = Key(key isa K ? key : convert(K, key)::K)

# The slot of `key` in `c`, or 0. A key that cannot be converted to `K` is not in the cache.
function _slot(c::SlotCache{K}, key) where {K}
    key isa K && return get(c.slots.index, Key(key), 0)
    k = try
        convert(K, key)::K
    catch
        return 0
    end
    return get(c.slots.index, Key(k), 0)
end

_entrysize(s::Slots, v) = s.by === nothing ? 1 : Int(s.by(v))::Int

# Insert a new key (not currently present), evicting until it fits.
# Values larger than the whole cache are not stored.
function _insert!(c::SlotCache, p::Key, v, sz::Int)
    s = c.slots
    sz > s.maxsize && return c
    while s.currentsize + sz > s.maxsize && !isempty(s.index)
        _free!(c, victim(c))
    end
    k = Key{Any}(p.key, p.hash)
    if isempty(s.free)
        push!(s.keys, k)
        push!(s.vals, v)
        push!(s.sizes, sz)
        i = length(s.keys)
    else
        i = pop!(s.free)
        s.keys[i], s.vals[i], s.sizes[i] = k, v, sz
    end
    s.index[k] = i
    s.currentsize += sz
    admit!(c, i)
    return c
end

# Free slot `i`: drop it from the index and clear its key and value so they can be
# garbage-collected while the slot sits on the free list.
function _free!(c::SlotCache, i::Int)
    forget!(c, i)
    s = c.slots
    delete!(s.index, s.keys[i])
    _unset!(s.keys, i)
    _unset!(s.vals, i)
    s.currentsize -= s.sizes[i]
    push!(s.free, i)
    return c
end

# `Base._unsetindex!` is internal, so fall back to keeping the reference if it ever disappears.
function _unset!(v::Vector, i::Int)
    @static if isdefined(Base, :_unsetindex!)
        Base._unsetindex!(v, i)
    end
    return v
end

function Base.get!(default::Base.Callable, c::SlotCache{K, V}, key) where {K, V}
    p = _newkey(c, key)
    s = c.slots
    @lock s.lock begin
        i = get(s.index, p, 0)
        if i != 0
            s.hits += 1
            touch!(c, i)
            return s.vals[i]
        end
        s.misses += 1
    end
    v = convert(V, default())::V
    sz = _entrysize(s, v)
    @lock s.lock begin
        # another task may have filled the key while we were computing
        i = get(s.index, p, 0)
        i == 0 || return s.vals[i]
        _insert!(c, p, v, sz)
    end
    return v
end

function Base.get(c::SlotCache, key, default)
    return @lock c.slots.lock begin
        i = _slot(c, key)
        i == 0 ? default : (touch!(c, i); c.slots.vals[i])
    end
end

function Base.getindex(c::SlotCache, key)
    return @lock c.slots.lock begin
        i = _slot(c, key)
        i == 0 && throw(KeyError(key))
        touch!(c, i)
        c.slots.vals[i]
    end
end

Base.haskey(c::SlotCache, key) = @lock c.slots.lock _slot(c, key) != 0
Base.length(c::SlotCache) = @lock c.slots.lock length(c.slots.index)
Base.isempty(c::SlotCache) = @lock c.slots.lock isempty(c.slots.index)

# Iteration walks a snapshot copied under the lock, so it is safe while other tasks use the
# cache (holding the lock across `iterate` calls would deadlock on an early `break`).
# The length may change between `length` and `iterate`, so `collect` must not rely on it.
Base.IteratorSize(::Type{<:SlotCache}) = Base.SizeUnknown()
function Base.iterate(c::SlotCache{K, V}) where {K, V}
    s = c.slots
    snapshot = @lock s.lock Pair{K, V}[k.key::K => s.vals[i] for (k, i) in s.index]
    return iterate(c, (snapshot, 1))
end
function Base.iterate(::SlotCache, (snapshot, i)::Tuple{Vector, Int})
    return i > length(snapshot) ? nothing : (snapshot[i], (snapshot, i + 1))
end

function Base.setindex!(c::SlotCache{K, V}, v, key) where {K, V}
    p = _newkey(c, key)
    val = convert(V, v)::V
    s = c.slots
    sz = _entrysize(s, val)
    @lock s.lock begin
        i = get(s.index, p, 0)
        i == 0 || _free!(c, i)
        _insert!(c, p, val, sz)
    end
    return c
end

function Base.delete!(c::SlotCache, key)
    @lock c.slots.lock begin
        i = _slot(c, key)
        i == 0 || _free!(c, i)
    end
    return c
end

# Frees every slot like `delete!` does, highest first so that refilling reuses them in order.
function Base.empty!(c::SlotCache)
    @lock c.slots.lock foreach(i -> _free!(c, i), sort!(collect(values(c.slots.index)); rev = true))
    return c
end

function Base.resize!(c::SlotCache; maxsize::Integer)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    s = c.slots
    @lock s.lock begin
        s.maxsize = maxsize
        while s.currentsize > s.maxsize && !isempty(s.index)
            _free!(c, victim(c))
        end
    end
    return c
end

function cache_stats(c::SlotCache)
    s = c.slots
    return @lock s.lock (; s.hits, s.misses, length = length(s.index), s.currentsize, s.maxsize, s.by)
end

# The entries below the compact header.
Base.show(io::IO, m::MIME"text/plain", c::SlotCache) = invoke(show, Tuple{IO, MIME"text/plain", AbstractDict}, io, m, c)
