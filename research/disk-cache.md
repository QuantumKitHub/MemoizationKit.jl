# Disk cache (2026-10-02)

A persistent level below the RAM caches, to replace the disk cache of SUNRepresentations.jl
(JLD2 files in a Scratch space, one file per `(N, T, s1, s2)` with one dataset per `s3`, Pidfile
locks, `USE_DISK_CACHE`, `clear_disk_cache!`, `disk_cache_info(; clean)`, `precompute_disk_cache`).
Its pain points: one file per group (inode quotas on GPFS `/mnt/home` and Ceph `/mnt/ceph`),
concurrency between processes, and fear of corrupt files. The user-facing description is
`docs/src/disk.md`.

## Decisions (with the user)

- **A separate style.** `DiskCacheStyle(f, args...)`, default `NoCache()`, independent of
  `CacheStyle`. Lookup order: RAM (per `CacheStyle`), then on a RAM miss the disk (per
  `DiskCacheStyle`), then compute and write to disk and RAM. With `NoCache` in RAM every call
  goes to disk. Both styles are constants at compile time.
- **One store per function** (per function type: callable objects with fields share a store, and
  the instance is part of their key).
- **SQLite** as the store, through SQLite.jl in the extension `CachedSQLiteExt` (weak dependency).
  WAL mode, `synchronous = NORMAL`, a busy timeout of 60 s, one statement (= transaction) per
  write. Table `entries(keyhash BLOB PRIMARY KEY, key BLOB, value BLOB)`: the key bytes are stored
  and compared in the query (`WHERE keyhash = ? AND key = ?`), so a hash collision is a miss.
- **Node-exclusive files**: the file name ends in `gethostname()`. WAL needs shared memory between
  the processes of a database, which network file systems do not give across nodes; the processes of
  one node share the file. Nodes do not share results.
- **Format through `Serialization`'s serializer types.** `DiskCache{S}()`, or
  `DiskCache(; serializer = Serializer)`; both keys and values are written with `S(io)` (header
  included). The key is hashed with SHA-256 (SHA stdlib).
- **Invalidation is the user's responsibility**: the only version in the file name is
  `Cached.diskversion(f)` (default `"1"`, overloadable): `<Module>.<f>-v<version>-<host>.sqlite`.
  The Julia version is not part of it. The docs say that `Serialization`'s format is not
  guaranteed across Julia versions (or type redefinitions), so users bump `diskversion` or use a
  stable serializer of their own; an entry that does not deserialize is a miss anyway.
- **Location**: the `disk_path` preference (function > package > `[Cached]`) >
  `Scratch.get_scratch!(owner, "Cached")`, with `owner` the root package of
  `parentmodule(typeof(f))`. Functions outside packages use `get_scratch!(Cached, "<root module>")`,
  i.e. `Main`. There is no runtime setter (one mechanism only), and no node-local default: the docs
  give the measured costs on GPFS/Ceph and suggest a local `disk_path` for cheap results.
- **Switches**: `disable_disk_caches!()`/`enable_disk_caches!()` (process-wide, an atomic flag read
  on the miss path only) and the `disk = false` preference (per function, package, or global,
  read when the function first opens its store). Disk caches are skipped during precompilation.
- **Robustness**: values read are checked `isa V` (the value type known in `_call`); an entry that
  cannot be deserialized or has the wrong type is a miss and is overwritten. Errors of the disk
  (cannot open, read or write, or a key or value that cannot be serialized) warn once and the call
  continues without the disk. A missing SQLite.jl is the one hard error, a `MethodError` of the
  internal `disk_lookup` with an error hint (the `EXTENSIONS` table in `src/api.jl`):
  "`DiskCache` needs SQLite.jl: run `using SQLite` first."
- **Management**, mirroring the RAM API: `disk_cache_info(f | m)` gives `f => (; path, entries,
  bytes)` for the current database of this node (for a module: of its functions used in this
  process, as `cache_info(m)`); `empty_disk_caches!(f | m)` deletes their entries. Files of older
  versions are not tracked; they are deleted by hand.

## Implementation

- `src/disk.jl` (~20 lines of code, the rest docstrings): `DiskCacheStyle`, `DiskCache{S}`,
  `diskversion`, `disk_artifact`, the process-wide switch, `_diskcall` (skips the disk when switched
  off or precompiling) and the stubs of `disk_lookup` and the management functions, which the
  extension implements. Without SQLite.jl a call is a `MethodError` of `disk_lookup` with the hint
  "`DiskCache` needs SQLite.jl" (the `EXTENSIONS` table in `src/api.jl`).
- `src/call.jl`: `call` adds `DiskCacheStyle(f, args...)`; `_call(f, style, ::NoCache, ...)` forwards
  to the unchanged six-argument `_call`, so functions without a disk cache compile to the same code.
  With a `DiskCache`, `_diskcall` replaces `_compute` as the miss function of `get!`, and is called
  directly under `NoCache`. A new instrumentation phase `:disk` wraps the disk lookup.
- `src/preferences.jl`: `disk` and `disk_path` are two more settings, returned by `_resolve_settings`.
- `ext/CachedSQLiteExt.jl` (~150 lines of code): everything else. A `Store` is a connection with two
  prepared statements and a lock (statements are not thread-safe); `Stores(f, artifact, node)` per
  function type, in an `IdDict` under a lock, opened outside the lock (opening can wait for the busy
  timeout) on first use. Artifacts open as a `file:...?mode=ro&immutable=1` URI, which takes no locks.
  All disk errors go through one `attempt(f, msg)`: warn once per message, continue without.
- Concurrent creation: two processes switching a new database to WAL at once can get
  `database is locked` without the busy timeout applying (each holds a shared lock and wants an
  exclusive one). Found by the stress test (1 in ~6 runs on 1.10); the setup is retried (`Base.retry`
  on "locked"), and `journal_mode` is only set when it is not WAL already.
- Stores are closed at exit (`atexit` in the extension's `__init__`), which checkpoints the WAL and
  removes the `-wal`/`-shm` files: an idle cache is one file per function and node.
- Simplified on 2026-10-02 from a first prototype (410 + 120 lines) that had a generic byte-store
  interface between core and extension, `set_disk_cache_dir!`/`disk_cache_dir`, a `DiskCacheFile`
  listing of every file of a function (other versions too) with stale-file deletion, and the Julia
  version in the file name.

## Dashboard (2026-10-03)

- **Counters.** Each store counts its lookups in this process, `hits` (read from the artifact or
  the node database) and `misses` (computed and written), in two `Threads.Atomic{Int}`, on the
  disk path only (RAM hits are untouched: 35 ns, 0 allocations). `Cached.disk_cache_stats()`
  (public, not exported, like `cache_stats`) lists `f => (; hits, misses)` for every open store,
  without I/O. `disk_cache_info` is unchanged.
- **Rows.** A function's RAM rows get `+disk` in the Kind column (5 → 10 columns wide, so Kind
  appears from 69 columns instead of 65, Activity from 78); a function with a disk cache and no
  registered RAM cache (`NoCache` in RAM, or task-local) gets a row of kind `Disk`, whose hit rate
  and sparkline are those of the disk and whose size cell reads `no limit (disk)`. Functions
  appear once their store is open (first call), as with RAM caches.
- **Detail.** One more line: disk hits, misses, lifetime disk hit rate, entries, bytes, path.
  `count(*)` measured on a 10^6-entry, 221 MiB database: 11 ms warm (local disk or GPFS), 1.8 ms
  at 10^5; cold over a network file system it reads the whole index, and `disk_cache_info` takes
  the store's lock, which a writer can hold for up to the 60 s busy timeout. So the entries are
  read for the selected row only, on a `Threads.@spawn` task collected by the next frame, at most
  every 10 s (or on `g`); `…` shows meanwhile. With one thread the task still shares the UI's
  thread while it runs.
- **Actions.** `e` empties RAM only; Enter resizes RAM only (the status bar says `(RAM)`); on a
  `Disk` row both just print a message pointing to `empty_disk_caches!`. The disk cannot be
  emptied from the dashboard at all: it is persistent, shared with the other processes of the node,
  expensive to refill, and one REPL call away; a confirmation dialog would be more code for a rare,
  destructive action.
- **Robustness.** Without SQLite (`applicable(Cached.disk_cache_stats)` is false) there are no
  disk rows. With `disable_disk_caches!()` the counters stop, the header says `disk caches off`
  and the disk line `disk (off)`. A function with `disk = false`, or whose files all failed to
  open, has no open store and is not listed as on disk; one with only an artifact shows `? entries`.

## Serializer types: how practical

Workable. A custom serializer is a `mutable struct S{I<:IO} <: AbstractSerializer` with fields
`io`, `counter`, `table`, `pending_refs` and `version` (`readheader` sets `version`), and a
constructor `S(io)`. `Serializer` itself also has `known_object_data`, used only for anonymous
functions and closures; `AbstractSerializer` has fallbacks for it, which is how
`Distributed.ClusterSerializer` gets by without it. Everything not overloaded is written as by
`Serializer`, so a package only writes `serialize(::S, ::MyType)`/`deserialize(::S, ::Type{MyType})`
for the types whose format it wants to control (tested with a `Point` stored as a string).

Caveats:
- the overloads use internals (`writetag`, `OBJECT_TAG`, `serialize_type`), the same ones that
  `Distributed` uses;
- everything not overloaded (the key, the tuple around it) is still in Serialization's format, so
  a custom serializer makes the file stable across Julia versions only as far as that format is.

The minimal alternative, if this turns out awkward, is a format hook
`Cached.disk_serialize(f, io, x)`/`disk_deserialize(f, io)`, defaulting to `Serialization`.

## Dependency footprint

- **Core**: `Scratch` 1.3, whose only dependencies are the stdlibs `Dates` (with `Printf`,
  `Unicode`); the stdlibs `SHA` and `Serialization` (in the default system image). `using Cached`
  takes 107 ms against 106 ms on `main`.
- **Extension**: `SQLite` 1.8 brings `SQLite_jll` (libsqlite3 3.51, 1.5 MB), `DBInterface`,
  `Tables` (with `DataAPI`, `DataValueInterfaces`, `IteratorInterfaceExtensions`, `TableTraits`,
  `OrderedCollections`), `WeakRefStrings` (with `InlineStrings`, `Parsers`), `JLLWrappers`,
  `PrecompileTools`, `Preferences`, and stdlibs. `using Cached, SQLite` takes ~250 ms; the
  extension itself precompiles in ~1 s.

## Measurements (ccqlin038, Julia 1.13, single thread)

| | main | disk-cache |
|:-|-:|-:|
| RAM hit, `Int` key | 35.6 ns, 0 allocs | 35.3–36.1 ns, 0 allocs |
| RAM hit, 4-tuple key | 39.0 ns, 0 allocs | 39.0 ns, 0 allocs |
| RAM hit of a function with a disk cache | | 35.3 ns, 0 allocs |

Disk path (`NoCache` in RAM, so every call reads the database):

| | local disk (`/tmp`) | GPFS (`/mnt/home`) | Ceph (`/mnt/ceph`) |
|:-|-:|-:|-:|
| hit, `Int` → `Int` | 4.6 µs | 0.6 ms | 0.24 ms |
| hit, 1000 `Float64` | 7.7 µs | | |
| hit, 10^5 `Float64` | 0.28 ms | | |
| miss: compute, write | 21 µs | 4.9 ms | 1.9 ms |

On network file systems each read takes POSIX locks on the database, which go through the network.
For results that take milliseconds or more to compute this is fine; otherwise put `disk_path` on a
local disk.

Stress test (`benchmark/disk_stress.jl`): 4 processes, each calling every key 3 times in its own
order, every value checked: 1500 keys on GPFS and on Ceph, 0 bad values, 1502 computations (the
rest read from disk).

## Artifacts (sketch, minimal helper implemented)

Lookup order RAM → artifact (read-only) → node store → compute. Implemented:
- `Cached.disk_artifact(f)` returns a directory (default `nothing`), e.g. `artifact"CGC"`. The
  file in it is `<Module>.<f>-v<version>.sqlite` (the store name without the host), opened
  `mode=ro&immutable=1`. A missing or unreadable file warns and is skipped.
- `export_disk_cache(f, dir)` writes the node's database into `dir` with `VACUUM INTO` (compact,
  consistent even while other processes write) and switches the copy to rollback-journal mode, so it
  can be read from a read-only directory without creating `-wal`/`-shm` files.

A package would then:

```julia
# once, by the maintainer
using Pkg.Artifacts, SUNRepresentations, Cached
SUNRepresentations.precompute(...)                  # fills the node store
hash = create_artifact(dir -> export_disk_cache(SUNRepresentations.CGC, dir))
archive_artifact(hash, "CGC-v1.tar.gz")   # upload; bind_artifact! in Artifacts.toml

# in the package
Cached.disk_artifact(::typeof(CGC)) = artifact"CGC"
```

One artifact covers one `diskversion`. If its format stops being readable by a newer Julia, its
entries are misses (recomputed into the node store); the package then ships a new artifact and
bumps `diskversion`.

## Later helpers (not built)

- **Merging node databases**: `ATTACH 'other.sqlite' AS o; INSERT OR IGNORE INTO entries SELECT * FROM o.entries;`
  into one file (e.g. to build an artifact from many nodes, or to compact per-host files). A
  `merge_disk_caches!(f, files)` would be ~15 lines in the extension.
- **Precompute driver**: like `precompute_disk_cache` in SUNRepresentations, generic over a list of
  arguments, with threads; probably better left to the package.

## Open questions

- **Directory per job or node**: `disk_path` is a fixed string, so a node-local directory that
  differs per job (e.g. `$TMPDIR`) cannot be expressed; a runtime setter was dropped for simplicity.
- **Network file system latency**: 0.3–0.7 ms per read on GPFS/Ceph. A per-process read connection
  held in `locking_mode = EXCLUSIVE` is not possible with several processes; documented instead.
- **Blob copies**: SQLite.jl copies a blob twice on read (it sniffs the column type by trying to
  deserialize it, then reads it), so a 10^5-element value costs ~0.3 ms. Reading through the C API
  (`sqlite3_column_blob`) would avoid that, at the cost of using SQLite.jl internals.
- **No size limit on disk.** Entries are never evicted; `empty_disk_caches!` is the only cleanup.
  An LRU on disk would need an access column and writes on reads.
- **`disk_cache_info(m::Module)`** and `empty_disk_caches!(m)` see only functions used in the
  process, and no files of older versions.
- **Corruption inside a value** (bit flips) is not detected: SQLite checks its pages' structure, not
  checksums of the content. A hash of the value could be stored with it.
- **Revise**: redefining a cached method does not invalidate its disk cache (nor its RAM cache);
  `diskversion` must be bumped by hand.
