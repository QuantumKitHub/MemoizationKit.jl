"""
    AbstractCache{K, V} <: AbstractDict{K, V}

Supertype of the size-bounded, thread-safe cache containers.

Every cache has a `maxsize` limit in the same units as its size measure: entry count by default,
or bytes (any unit) when constructed with a `by` function that measures values.
Lookups through [`get!`](@ref) never hold the lock while computing a missing value, so cached
functions may recurse into the same cache, and an exception leaves the cache unchanged.

Subtypes provide the fields `index::Dict{K,Int}`, `keys`, `vals`, `sizes`, `currentsize`,
`maxsize`, `by`, `hits`, `misses` and `lock`, and implement the eviction policy through
`_touch!`, `_evict_one!`, `_place!` and `_remove!`.
"""
abstract type AbstractCache{K, V} <: AbstractDict{K, V} end

_entrysize(c::AbstractCache, v) = c.by === nothing ? 1 : Int(c.by(v))::Int

# Insert a new key (not currently present), evicting until it fits.
# Values larger than the whole cache are not stored.
function _insert!(c::AbstractCache, k, v, sz::Int)
    sz > c.maxsize && return c
    while c.currentsize + sz > c.maxsize && !isempty(c.index)
        _evict_one!(c)
    end
    i = isempty(c.free) ? _newslot!(c, k, v, sz) : _reuseslot!(c, pop!(c.free), k, v, sz)
    c.index[k] = i
    _place!(c, i)
    c.currentsize += sz
    return c
end

function _reuseslot!(c::AbstractCache, i::Int, k, v, sz::Int)
    c.keys[i] = k
    c.vals[i] = v
    c.sizes[i] = sz
    return i
end

function Base.get!(default::Base.Callable, c::AbstractCache{K, V}, key) where {K, V}
    k = convert(K, key)::K
    @lock c.lock begin
        i = get(c.index, k, 0)
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
        i = get(c.index, k, 0)
        i == 0 || return c.vals[i]
        _insert!(c, k, v, sz)
    end
    return v
end

function Base.get(c::AbstractCache, key, default)
    return @lock c.lock begin
        i = get(c.index, key, 0)
        i == 0 ? default : (_touch!(c, i); c.vals[i])
    end
end

function Base.getindex(c::AbstractCache, key)
    return @lock c.lock begin
        i = get(c.index, key, 0)
        i == 0 && throw(KeyError(key))
        _touch!(c, i)
        c.vals[i]
    end
end

Base.haskey(c::AbstractCache, key) = @lock c.lock haskey(c.index, key)
Base.length(c::AbstractCache) = length(c.index)
Base.isempty(c::AbstractCache) = isempty(c.index)

function Base.setindex!(c::AbstractCache{K, V}, v, key) where {K, V}
    k = convert(K, key)::K
    val = convert(V, v)::V
    sz = _entrysize(c, val)
    @lock c.lock begin
        i = get(c.index, k, 0)
        i == 0 || _remove!(c, i)
        _insert!(c, k, val, sz)
    end
    return c
end

function Base.delete!(c::AbstractCache, key)
    @lock c.lock begin
        i = get(c.index, key, 0)
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
