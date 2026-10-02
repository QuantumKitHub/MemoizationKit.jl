"""
    AbstractCache{K, V} <: AbstractDict{K, V}

Supertype of the size-bounded, thread-safe cache containers.

Every cache has a `maxsize` limit in the same units as its size measure: entry count by default,
or bytes (any unit) when constructed with a `by` function that measures values.
Lookups through `get!` never hold the lock while computing a missing value, so cached
functions may recurse into the same cache, and an exception leaves the cache unchanged.

Keys of different types never match, even when they are `isequal`: in a cache with an
abstract key type, `1` and `1.0` are different entries. Lookups with a key that is not of type
`K` convert it to `K` first.

Subtypes provide the fields `index::Dict{Key{Any},Int}`, `keys::Vector{Key{Any}}`, `vals`,
`sizes`, `currentsize`, `maxsize`, `by`, `hits`, `misses` and `lock`, and implement the eviction
policy through `_touch!`, `_evict_one!`, `_place!` and `_remove!`.
"""
abstract type AbstractCache{K, V} <: AbstractDict{K, V} end

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

# The probe for a key that is inserted: converted to `K`, which throws if that is not possible.
_newkey(::AbstractCache{K}, key) where {K} = Key(key isa K ? key : convert(K, key)::K)

# The slot of `key` in `c`, or 0. A key that cannot be converted to `K` is not in the cache.
function _slot(c::AbstractCache{K}, key) where {K}
    key isa K && return get(c.index, Key(key), 0)
    k = try
        convert(K, key)::K
    catch
        return 0
    end
    return get(c.index, Key(k), 0)
end

_entrysize(c::AbstractCache, v) = c.by === nothing ? 1 : Int(c.by(v))::Int

# Insert a new key (not currently present), evicting until it fits.
# Values larger than the whole cache are not stored.
function _insert!(c::AbstractCache, p::Key, v, sz::Int)
    sz > c.maxsize && return c
    while c.currentsize + sz > c.maxsize && !isempty(c.index)
        _evict_one!(c)
    end
    k = Key{Any}(p.key, p.hash)
    i = isempty(c.free) ? _newslot!(c, k, v, sz) : _reuseslot!(c, pop!(c.free), k, v, sz)
    c.index[k] = i
    _place!(c, i)
    c.currentsize += sz
    return c
end

# Release slot `i`: drop it from the index and clear its key and value so they can be
# garbage-collected while the slot sits on the free list.
function _freeslot!(c::AbstractCache, i::Int)
    delete!(c.index, c.keys[i])
    _unset!(c.keys, i)
    _unset!(c.vals, i)
    c.currentsize -= c.sizes[i]
    push!(c.free, i)
    return c
end

# `Base._unsetindex!` is internal, so fall back to keeping the reference if it ever disappears.
function _unset!(v::Vector, i::Int)
    @static if isdefined(Base, :_unsetindex!)
        Base._unsetindex!(v, i)
    end
    return v
end

function _reuseslot!(c::AbstractCache, i::Int, k, v, sz::Int)
    c.keys[i] = k
    c.vals[i] = v
    c.sizes[i] = sz
    return i
end

function Base.get!(default::Base.Callable, c::AbstractCache{K, V}, key) where {K, V}
    p = _newkey(c, key)
    @lock c.lock begin
        i = get(c.index, p, 0)
        if i != 0
            c.hits += 1
            _touch!(c, i)
            return c.vals[i]
        end
        c.misses += 1
    end
    v = convert(V, default())::V
    sz = _entrysize(c, v)
    @lock c.lock begin
        # another task may have filled the key while we were computing
        i = get(c.index, p, 0)
        i == 0 || return c.vals[i]
        _insert!(c, p, v, sz)
    end
    return v
end

function Base.get(c::AbstractCache, key, default)
    return @lock c.lock begin
        i = _slot(c, key)
        i == 0 ? default : (_touch!(c, i); c.vals[i])
    end
end

function Base.getindex(c::AbstractCache, key)
    return @lock c.lock begin
        i = _slot(c, key)
        i == 0 && throw(KeyError(key))
        _touch!(c, i)
        c.vals[i]
    end
end

Base.haskey(c::AbstractCache, key) = @lock c.lock _slot(c, key) != 0
Base.length(c::AbstractCache) = @lock c.lock length(c.index)
Base.isempty(c::AbstractCache) = @lock c.lock isempty(c.index)

# Iteration walks a snapshot copied under the lock, so it is safe while other tasks use the
# cache (holding the lock across `iterate` calls would deadlock on an early `break`).
# The length may change between `length` and `iterate`, so `collect` must not rely on it.
Base.IteratorSize(::Type{<:AbstractCache}) = Base.SizeUnknown()
function Base.iterate(c::AbstractCache)
    snapshot = @lock c.lock _pairs(c)
    return iterate(c, (snapshot, 1))
end
function Base.iterate(::AbstractCache, (snapshot, i)::Tuple{Vector, Int})
    return i > length(snapshot) ? nothing : (snapshot[i], (snapshot, i + 1))
end

function Base.setindex!(c::AbstractCache{K, V}, v, key) where {K, V}
    p = _newkey(c, key)
    val = convert(V, v)::V
    sz = _entrysize(c, val)
    @lock c.lock begin
        i = get(c.index, p, 0)
        i == 0 || _remove!(c, i)
        _insert!(c, p, val, sz)
    end
    return c
end

function Base.delete!(c::AbstractCache, key)
    @lock c.lock begin
        i = _slot(c, key)
        i == 0 || _remove!(c, i)
    end
    return c
end

"""
    resize!(c::AbstractCache; maxsize::Integer)

Change the size limit of `c`, evicting entries until it fits.
"""
function Base.resize!(c::AbstractCache; maxsize::Integer)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    @lock c.lock begin
        c.maxsize = maxsize
        while c.currentsize > c.maxsize && !isempty(c.index)
            _evict_one!(c)
        end
    end
    return c
end

"""
    cache_stats(c::AbstractCache) -> NamedTuple

Return `(; hits, misses, length, currentsize, maxsize)` for `c`.
"""
cache_stats(c::AbstractCache) = @lock c.lock (;
    c.hits, c.misses, length = length(c.index), c.currentsize, c.maxsize,
)

# Compact form, also used as the header of the multi-line `show` inherited from `AbstractDict`.
function Base.show(io::IO, c::AbstractCache)
    s = cache_stats(c)
    print(io, typeof(c), "(")
    c.by === nothing ? print(io, s.length, "/", s.maxsize, " entries") :
        print(io, s.length, " entries, size ", s.currentsize, "/", s.maxsize)
    print(io, ", ", s.hits, " hits, ", s.misses, " misses)")
    return nothing
end
Base.summary(io::IO, c::AbstractCache) = show(io, c)
