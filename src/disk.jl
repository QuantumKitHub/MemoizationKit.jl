# Disk caching, a level below the RAM caches (see `docs/src/disk.md`). The core holds the API;
# the stores are implemented by the SQLite extension, `ext/CachedSQLiteExt.jl`.

"""
    DiskCacheStyle(f, args...)

The disk caching strategy for the call `f(args...)` of a [`@cached`](@ref) function:
[`NoCache()`](@ref NoCache) (the default) or a [`DiskCache`](@ref). It is independent of
[`CacheStyle`](@ref): the disk is consulted when the RAM cache misses, or on every call when
`CacheStyle` is `NoCache()`.

```julia
Cached.DiskCacheStyle(::typeof(f), args...) = DiskCache()
```
"""
DiskCacheStyle(f, args...) = NoCache()

"""
    DiskCache{S}()
    DiskCache(; serializer = Serialization.Serializer)

Disk caching strategy, returned by [`DiskCacheStyle`](@ref): results are stored in an SQLite
database per function and node, written with the serializer type `S <: AbstractSerializer`.
Needs SQLite.jl (`using SQLite`).
"""
struct DiskCache{S}
    function DiskCache{S}() where {S}
        S <: AbstractSerializer || throw(ArgumentError("DiskCache requires an AbstractSerializer, got $S"))
        return new{S}()
    end
end
DiskCache(; serializer::Type = Serializer) = DiskCache{serializer}()

"""
    Cached.diskversion(f) -> String

Version of the disk cache of `f`, part of its file name; `"1"` by default. Change it when the
stored results of `f` are no longer valid, or no longer readable (e.g. after a Julia update).
"""
diskversion(f) = "1"

"""
    Cached.disk_artifact(f) -> Union{Nothing, String}

A directory with a read-only disk cache of `f`, made by [`export_disk_cache`](@ref), that is
consulted before the cache of the node, e.g. `artifact"CGC"`. Defaults to `nothing`.
"""
disk_artifact(f) = nothing

const DISK_ENABLED = Threads.Atomic{Bool}(true)

"""
    disable_disk_caches!()

Turn all disk caches off in this process, until [`enable_disk_caches!`](@ref).
"""
disable_disk_caches!() = (DISK_ENABLED[] = false; nothing)

"""
    enable_disk_caches!()

Turn disk caches back on, after [`disable_disk_caches!`](@ref).
"""
enable_disk_caches!() = (DISK_ENABLED[] = true; nothing)

# Called on a miss of the RAM cache (or on every call, with `NoCache` in RAM).
function _diskcall(f::F, disk::DiskCache, ::Type{V}, key, args, kw) where {F, V}
    o = _ownerval(F)
    (DISK_ENABLED[] && ccall(:jl_generating_output, Cint, ()) == 0) || return _compute(f, o, args, kw)
    return disk_lookup(f, disk, V, key, args, kw, o)
end

# The disk lookup, defined by the SQLite extension; without it, a call has a hint to load SQLite.
function disk_lookup end

"""
    disk_cache_info(f) -> Vector{Pair{Any, NamedTuple}}
    disk_cache_info(m::Module) -> Vector{Pair{Any, NamedTuple}}

The disk cache of `f` on this node, or those of the functions owned by `m` or its submodules
that have been used in this process, as `f => (; path, entries, bytes)` pairs.
"""
function disk_cache_info end

"""
    Cached.disk_cache_stats() -> Vector{Pair{Any, NamedTuple}}

The disk lookups in this process of each function whose disk cache is open, as
`f => (; hits, misses)` pairs, where a hit is a result read from disk (from the artifact or
the database of the node) and a miss a result computed and written. Unlike
[`disk_cache_info`](@ref), it reads no files.
"""
function disk_cache_stats end

"""
    empty_disk_caches!(f)
    empty_disk_caches!(m::Module)

Remove the entries of the disk cache of `f` on this node, or of the caches listed by
[`disk_cache_info(m)`](@ref disk_cache_info).
"""
function empty_disk_caches! end

"""
    export_disk_cache(f, dir) -> String

Write the disk cache of `f` on this node into `dir`, as a compact read-only database named as
[`Cached.disk_artifact`](@ref) expects it, and return its path.
"""
function export_disk_cache end
