"""
    AbstractCache{K, V} <: AbstractDict{K, V}

Supertype of the containers of [`GlobalCache`](@ref) and [`TaskLocalCache`](@ref). A subtype
`C` implements `C{K, V}(; maxsize, by)`, `get!(default, c, key)`, `empty!(c)`,
[`resize!(c; maxsize)`](@ref resize!(::MemoizationKit.AbstractCache)) and [`MemoizationKit.cache_stats(c)`](@ref);
see [Implementing a cache](@ref). Other `AbstractDict` methods are optional.

[`LRU`](@ref) and [`ClockCache`](@ref) are thread-safe dictionaries that convert keys to `K`.
"""
abstract type AbstractCache{K, V} <: AbstractDict{K, V} end

"""
    resize!(c::AbstractCache; maxsize::Integer) -> c

Set the size limit of `c`, evicting entries until they fit.
"""
Base.resize!(::AbstractCache; maxsize)

"""
    cache_stats(c::AbstractCache) -> NamedTuple

`(; hits, misses, length, currentsize, maxsize, by)` of `c`, where `currentsize` is the total size
of the entries and `by` the size measure (`nothing` when counting entries).
"""
function cache_stats end

# The compact form, from `cache_stats` only; dict-like caches print it above their entries.
function Base.show(io::IO, c::AbstractCache)
    s = cache_stats(c)
    print(io, typeof(c), "(")
    s.by === nothing ? print(io, s.length, "/", s.maxsize, " entries") :
        print(io, s.length, " entries, size ", s.currentsize, "/", s.maxsize)
    print(io, ", ", s.hits, " hits, ", s.misses, " misses)")
    return nothing
end
Base.summary(io::IO, c::AbstractCache) = show(io, c)
Base.show(io::IO, ::MIME"text/plain", c::AbstractCache) = show(io, c)
