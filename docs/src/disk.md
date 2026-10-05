# Disk caching

```@meta
CurrentModule = Cached
```

Results that are expensive to compute can also be kept on disk, so that they survive the process.
The disk is a second level below the cache in memory: a call looks in RAM first (as chosen by [`CacheStyle`](@ref)), then on disk, and only computes when both miss, after which the result is written to both.

Disk caching is a package extension on [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl): load it with `using SQLite`, or, in a package, add SQLite to its dependencies and `import SQLite`.

```julia
using Cached, SQLite

@cached function expensive(n::Int)::Matrix{Float64}
    sleep(1) # stand-in for an expensive computation
    [Float64(i == j) for i in 1:n, j in 1:n]
end

Cached.DiskCacheStyle(::typeof(expensive), args...) = DiskCache()
```

## Choosing what goes to disk

[`DiskCacheStyle`](@ref)`(f, args...)` selects the disk strategy per function and argument types, independently of `CacheStyle`: [`NoCache()`](@ref NoCache) (the default) or a [`DiskCache`](@ref).
Both resolve at compile time, so functions without a disk cache are not affected, and a RAM hit costs the same with or without one.

| `CacheStyle` | `DiskCacheStyle` | a call |
| :--- | :--- | :--- |
| `GlobalCache()` (default) | `NoCache()` (default) | RAM, else compute |
| `GlobalCache()` | `DiskCache()` | RAM, else disk, else compute |
| `NoCache()` | `DiskCache()` | disk, else compute, on every call |

## Where the data goes

Each function has one SQLite database per machine, `<Module>.<f>-v<version>-<host>.sqlite`.
The directory is the `disk_path` preference of the function, its package, or Cached (see [Configuration](configuration.md)), and by default a [scratch space](https://github.com/JuliaPackaging/Scratch.jl) of the package that owns `f`.
Functions outside packages (in scripts or the REPL) use a scratch space of Cached.

```julia
set_cache_preferences!(MyPackage; disk_path = "/path/to/cache")
```

- **One file per function and machine**, whatever the number of entries, which matters on file systems that limit the number of files.
- **Processes on one machine share the database**, reading and writing at the same time.
  A write is a transaction, so an interrupted process never leaves a partial entry.
- **Machines write separate files**, named after the host, since SQLite's locking does not work across machines on a shared file system.
  Results are not shared between machines.

Disk lookups take file locks, which can be slow on network storage.
Use a local `disk_path` when possible, and reserve disk caching for expensive computations.
Disk storage has no automatic size limit or eviction; use [`empty_disk_caches!`](@ref) to reclaim space in the current database.

## Versions

The file name holds a version, [`Cached.diskversion(f)`](@ref), `"1"` by default.
Keeping it current is up to you: bump it when the results of `f` change, and the old file is no longer read.

```julia
Cached.diskversion(::typeof(expensive)) = "2"
```

The default format is that of `Serialization`, which is not guaranteed to be readable by other Julia versions, nor after the definition of a stored type changes.
Bump the version when that happens, or write a stable format with a serializer of your own (below).

Entries that cannot be read, or are not of the value type of the call, count as misses and are overwritten.
Errors of the disk itself, such as a full disk, never fail a call: they are reported once, and the call goes on without the disk.

## Formats

Keys and values are written with `Serialization`, indexed by the SHA-256 hash of the serialized key; the key is stored too, to guard against hash collisions.

[`Cached.cachekey`](@ref) selects the key for both RAM and disk caching.
To share disk entries between equivalent inputs, return a canonical representation that serializes to the same bytes.
[`Hashed`](@ref) changes RAM hashing and equality, but its wrapped value is still serialized, so custom equality alone does not merge disk entries.
See [Custom cache keys](keys.md) for examples and the equality contract.

The serializer is a parameter of the style, `DiskCache(; serializer = Serializer)`.
To choose the format of some types, define a serializer type with its own `serialize` and `deserialize` methods for them; everything else is written as by `Serialization`.
A serializer is a mutable `AbstractSerializer` with these fields and a constructor from an `IO`:

```julia
using Serialization
using Serialization: AbstractSerializer

mutable struct MySerializer{I <: IO} <: AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any, Any}
    pending_refs::Vector{Int}
    version::Int
    MySerializer(io::I) where {I <: IO} = new{I}(io, 0, IdDict(), Int[], 0)
end

function Serialization.serialize(s::MySerializer, x::MyType)
    Serialization.writetag(s.io, Serialization.OBJECT_TAG)
    serialize(s, typeof(x))
    # write `x` to `s.io` in your own format
end
function Serialization.deserialize(s::MySerializer, ::Type{T}) where {T <: MyType}
    # read it back
end

Cached.DiskCacheStyle(::typeof(expensive), args...) = DiskCache(; serializer = MySerializer)
```

`writetag` and `OBJECT_TAG` are internals of `Serialization`, used the same way by `Distributed`'s `ClusterSerializer`.

## Turning it off

[`disable_disk_caches!()`](@ref disable_disk_caches!) turns all disk caches off in this process, and [`enable_disk_caches!()`](@ref enable_disk_caches!) back on; while off, nothing is read from or written to disk.
The `disk = false` preference turns them off per function, package, or globally:

```julia
set_cache_preferences!(MyPackage; disk = false)
```

`disk` and `disk_path` are read when a function first uses its disk cache in a session.
Disk caches are never used during precompilation.

## Managing disk caches

```julia
disk_cache_info(expensive)     # [expensive => (; path, entries, bytes)]
disk_cache_info(MyPackage)     # ... of its functions used in this process
empty_disk_caches!(expensive)  # remove the entries
Cached.disk_cache_stats()      # [expensive => (; hits, misses), ...] in this process
```

[`disk_cache_info`](@ref) and [`empty_disk_caches!`](@ref) act on this machine's current database; files of older versions or other machines are left alone.
The Disk tab of the [dashboard](dashboard.md) lists the open disk caches with these numbers.

## Precomputed results as an artifact

A package can ship precomputed results, read-only, as a [Pkg artifact](https://pkgdocs.julialang.org/v1/artifacts/): fill the disk cache, export it with [`export_disk_cache`](@ref), and point [`Cached.disk_artifact`](@ref) at the artifact.

```julia
using Pkg.Artifacts
hash = create_artifact() do dir
    foreach(expensive, 1:100)          # fill the disk cache
    export_disk_cache(expensive, dir)  # writes <Module>.expensive-v<version>.sqlite
end
# archive, upload and bind it in Artifacts.toml as usual; then, in the package:
Cached.disk_artifact(::typeof(expensive)) = artifact"expensive"
```

A call then looks in RAM, the artifact, and this machine's database, in that order, and only then computes.
New results go to the database; the artifact is never written, and holds the results of one version of `f`.
