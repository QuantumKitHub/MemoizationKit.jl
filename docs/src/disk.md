# Disk caching

```@meta
CurrentModule = Cached
```

Results that are expensive to compute can also be kept on disk, so that they survive the
process. Disk caching is a second level below the cache in memory: a call looks in RAM first
(as chosen by [`CacheStyle`](@ref)), then on disk, and only computes on a miss of both, after
which the result is written to disk and to RAM.

It is a package extension on [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl): load
it with `using SQLite`, or, in a package, add SQLite to its dependencies and `import SQLite`.

```julia
using Cached, SQLite

@cached function CGC(T::Type{<:Real}, s1::I, s2::I, s3::I) where {I <: SUNIrrep}
    # expensive
end

Cached.DiskCacheStyle(::typeof(CGC), args...) = DiskCache()
```

## Choosing what goes to disk

[`DiskCacheStyle`](@ref)`(f, args...)` selects the disk strategy per function and argument
types, independently of `CacheStyle`: [`NoCache()`](@ref NoCache) (the default) or a
[`DiskCache`](@ref). Both resolve at compile time, so functions without disk caching are not
affected at all, and a RAM hit costs the same with or without a disk cache.

| `CacheStyle` | `DiskCacheStyle` | a call |
|:-|:-|:-|
| `GlobalCache()` (default) | `NoCache()` (default) | RAM, else compute |
| `GlobalCache()` | `DiskCache()` | RAM, else disk, else compute |
| `NoCache()` | `DiskCache()` | disk, else compute, on every call |

## Where the data goes

Each function has one SQLite database per node, `<Module>.<f>-v<version>-<host>.sqlite`. The
directory is the `disk_path` preference of the function, its package, or Cached (see
[Configuration](configuration.md)), and by default a
[scratch space](https://github.com/JuliaPackaging/Scratch.jl) of the package that owns `f`,
`Scratch.get_scratch!(package, "Cached")`, in the Julia depot. Functions outside packages (in
scripts or the REPL) use a scratch space of Cached named after their module, e.g. `Main`.

```julia
set_cache_preferences!(SUNRepresentations; disk_path = "/scratch/me/cgc")
```

- **One file per function and node.** A database is one file, whatever the number of entries
  (two more, the write-ahead log and its index, exist while it is open), which matters on file
  systems with inode quotas.
- **Processes on one node share the database.** SQLite's write-ahead log lets them read and
  write at the same time; a write is a transaction, so an interrupted process never leaves a
  partial entry.
- **Nodes write separate files**, named after the host: SQLite's locking does not work between
  nodes on network file systems. Results are not shared between nodes.

### Speed

Every disk lookup takes SQLite's file locks, which on a network file system go through the
network. Measured with `NoCache` in RAM, so that every call reads the database:

| | local disk | GPFS | Ceph |
|:-|-:|-:|-:|
| hit, `Int` → `Int` | 5 µs | 0.6 ms | 0.25 ms |
| hit, 10^5 `Float64` | 0.3 ms | | |
| miss: compute and write | 20 µs | 5 ms | 2 ms |

This is negligible for results that take milliseconds or more to compute. For cheaper ones,
point `disk_path` at a local disk.

## Versions

The file name holds a version, [`Cached.diskversion(f)`](@ref), `"1"` by default. Keeping it
current is up to you: bump it when the results of `f` change, and the old file is no longer
read:

```julia
Cached.diskversion(::typeof(CGC)) = "2"
```

The default format is that of `Serialization`, which is not guaranteed to be readable by
other Julia versions, nor after the definition of a stored type changes. Bump the version
when that happens, or use a serializer of your own (below) that writes a stable format.

Entries that cannot be read, or that are not of the value type of the call, count as misses
and are overwritten. Errors of the disk itself (a full disk, no write access) never fail a
call: they are reported once, and the call goes on without the disk.

## Formats

Keys and values are written with `Serialization`. The key is serialized too, and stored next
to its SHA-256 hash, which indexes the table; the stored key guards against hash collisions.

The serializer is a type parameter of the style, `DiskCache(; serializer = Serializer)`. To
pick the format of some types, for instance a stable or more compact one, define a serializer
type and give its own `serialize`/`deserialize` methods to those types; everything else is
written as by `Serialization`. A serializer is a mutable `AbstractSerializer` with the fields
below and a constructor from an `IO`:

```julia
using Serialization
using Serialization: AbstractSerializer

mutable struct CGCSerializer{I <: IO} <: AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any, Any}
    pending_refs::Vector{Int}
    version::Int
    CGCSerializer(io::I) where {I <: IO} = new{I}(io, 0, IdDict(), Int[], 0)
end

function Serialization.serialize(s::CGCSerializer, a::SparseArray)
    Serialization.writetag(s.io, Serialization.OBJECT_TAG)
    serialize(s, typeof(a))
    # write `a` in your own format to `s`, e.g. its nonzero entries
end
function Serialization.deserialize(s::CGCSerializer, ::Type{T}) where {T <: SparseArray}
    # read it back
end

Cached.DiskCacheStyle(::typeof(CGC), args...) = DiskCache(; serializer = CGCSerializer)
```

`writetag` and `OBJECT_TAG` are internals of `Serialization`, used the same way by
`Distributed`'s `ClusterSerializer`.

## Turning it off

- [`disable_disk_caches!()`](@ref disable_disk_caches!) turns all disk caches off in this
  process, and [`enable_disk_caches!()`](@ref enable_disk_caches!) back on. While off, nothing
  is read from or written to disk, which is useful during development, when old results on
  disk may be stale.
- The `disk = false` preference turns them off per function, package, or globally:

```julia
set_cache_preferences!(SUNRepresentations; disk = false)
```

`disk` and `disk_path` are read when a function first uses its disk cache in a session. Disk
caches are never used during precompilation.

## Managing disk caches

```julia
disk_cache_info(CGC)                 # [CGC => (; path, entries, bytes)]
disk_cache_info(SUNRepresentations)  # ... of its functions used in this process
empty_disk_caches!(CGC)              # remove the entries
```

[`disk_cache_info`](@ref) and [`empty_disk_caches!`](@ref) act on the current database of this
node. Files of older versions, or of other nodes, are left alone; delete them by hand when no
process uses them.

## Precomputed results as an artifact

A package can ship precomputed results, read-only, as a
[Pkg artifact](https://pkgdocs.julialang.org/v1/artifacts/). Compute them, and export the
database of this node with [`export_disk_cache`](@ref), which writes a compact copy named
`<Module>.<f>-v<version>.sqlite`:

```julia
using Pkg.Artifacts
hash = create_artifact() do dir
    SUNRepresentations.precompute(...)  # fill the disk cache of CGC
    export_disk_cache(CGC, dir)
end
# then archive it, upload it and bind it in Artifacts.toml as usual
```

and point [`Cached.disk_artifact`](@ref) at it:

```julia
Cached.disk_artifact(::typeof(CGC)) = artifact"CGC"
```

A call then looks in RAM, then in the artifact, then in the database of the node, and only
then computes. New results go to the database of the node; the artifact is never written. The
artifact holds the results of one version of `f`.
