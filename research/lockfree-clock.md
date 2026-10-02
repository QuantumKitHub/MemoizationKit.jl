# Lock-free hits for ClockCache

Investigation of 2026-10-02 (branch `lockfree-clock`), adopted: `ClockCache` is now the lock-free design described here, and the locked design lives on as the internal `LocalClockCache` for task-local caches.

## Summary

- **`ClockCache`** (`src/containers/clock.jl`) is an open-addressing hash table of immutable entries with a CLOCK ring next to it. Readers take no lock and write no shared cache line. Every mutation still runs under the one `ReentrantLock`.
- **Hits**:
  - They scale: a shared-cache hit stays at 24–45 ns from 1 to 16 threads. The locked design went from 31 to about 1000 ns.
  - They are faster than task-local caches.
  - They are also **2× faster single-threaded** (14 vs 31 ns for `Int` keys, 24 vs 39 ns for 4-tuples), because a hit no longer takes and releases a lock.
  - Hits stay inferred and allocate nothing, on 1.10 through 1.13.
- **Misses** still serialize on the lock. With trivial computations they are only 1.3–1.6× faster than with the locked design (for example 3.9 vs 6.4 µs per lookup at 16 threads on Zipf). A miss allocates about 45 B more (one `Entry` object), and a stored entry uses about 25 B more.
- **Sharding the lock (16 or 64 locked caches) does not fix hits.** Every thread touches every shard's lock, so the cache lines still bounce. At 8+ threads, 16 shards were slower than one lock, and 64 shards about equal. Sharding does help miss-heavy workloads (2–5×). The `ShardedCache` prototype was dropped; its numbers are kept below.
- Sharding *lock-free* caches gave the best mixed-workload numbers in a quick experiment (below). It costs a per-shard budget, so it is a follow-up, not adopted.
- **Task-local caches** keep the locked design (`LocalClockCache`): a single task gains nothing from lock-free hits, and the per-thread counters would cost 64 B per thread in every task's cache.
- **Complexity**: about 200 lines of code plus about 60 lines of comments in `clock.jl`, against 86 lines for the locked design (`localclock.jl`), which also uses most of `interface.jl`. There are 3 core invariants and a few local rules (listed below). It needs no new dependencies.

## Q1: why the `Dict` index cannot be read without the lock

A lock-free read of the `Dict` is **memory-unsafe**, not just stale. The Julia manual says so in general: "If data-races are introduced, Julia is not memory safe". The `Dict` code makes it concrete.

- **`ht_keyindex` on 1.13** (`base/dict.jl:238`) reads `sz = length(h.keys)` and `keys = h.keys` once. Inside an `@inbounds` loop annotated `:noub`, it reads `h.slots` on every probe step (`isslotempty(h, index)`).
  - `rehash!` replaces `h.slots`, `h.keys` and `h.vals` with new `Memory`s.
  - It is called from `_setindex!` when `(count + ndel)*3 > 2sz`, with the new size `max(count*4, 4)`. After many deletions this is *smaller* than the old size, which is exactly the steady churn of a full cache.
  - A reader then indexes the new, smaller `slots` with an index computed for the old size. That is an out-of-bounds read.
- **`empty!` on 1.10** does `empty!(h.keys); resize!(h.keys, sz)`. On 1.11+ it `_unsetindex!`es every slot.
- **The stored keys are inline `Key{Any}`s** (a pointer and a hash, two words). A concurrent write is not atomic, so a reader can see a torn key or a null pointer.

**A seqlock (optimistic read, then validate a version counter) does not help.** Validation happens after the read, but the read itself can already crash. A seqlock needs a structure whose reads are memory-safe under concurrent mutation, and once a table has that property (as below), immutable entries make the version counter unnecessary.

**No Base structure gives safe concurrent reads on 1.10.**

- `Dict`, `IdDict` and `WeakKeyDict` all lock or are unsafe in the same way.
- `Base.Lockable` is just a lock.
- `Base.PersistentDict` (a HAMT, 1.11+, internal, used by ScopedValues) is immutable, so a published snapshot would be safe to read. It is not on 1.10, every insert copies a path and allocates, and the CLOCK ring would still be separate.
- ConcurrentCollections.jl would add a dependency.

## Q2: candidate designs

| design | hits lock-free | memory-safe on 1.10 | miss cost | verdict |
|:-|:-|:-|:-|:-|
| (a) seqlock over the `Dict` | yes | **no** (see Q1) | unchanged | rejected |
| (b) fixed-size open-addressing table of immutable entries, replaced whole when full; acquire loads | yes | yes | +1 allocation (48 B), rare O(n) rebuild | **adopted** |
| (c) copy-on-write snapshot of the index on every write | yes | yes | O(capacity) per miss: a 10k-entry rebuild takes 0.2–0.35 ms (measured with `_rebuild!`), against about 0.1 µs now | rejected for caches with frequent misses |
| (d) sharded locks (16 or 64 locked caches) | no | yes | lower contention | prototyped (`ShardedCache`); does not fix hits |
| (e) reader–writer lock | no | yes | — | not built: every reader still does an atomic RMW on the shared reader count, which bounces the same cache line as the lock does now |
| (b) + (d): shards of lock-free caches | yes | yes | best under contention | measured as an experiment; per-shard budgets |

**Counters.** A shared `hits += 1`, atomic or not, bounces a cache line on every hit. In my numbers that alone keeps a "lock-free" design from scaling.

- `ClockCache` counts hits and misses **per thread**, in separate 64-byte lines (`counts[8*(tid-1) + which]`), using a relaxed load and a relaxed store.
- The counts are exact: two tasks on one thread cannot interleave between the load and the store, since neither yields.
- Threads adopted after the cache was created (foreign threads) wrap around and may lose a few counts.
- The cost is `64 × maxthreadid()` bytes per cache, about 1 KB at 16 threads. That matters only if there are very many caches, so task-local caches use the locked `LocalClockCache`.

## Q3: the reference bit

The bit moved into the entry, as an `@atomic ref::Bool` field of the mutable `Entry`. This sidesteps the "no atomic vector elements on 1.10" problem entirely.

- A hit does `(@atomic :monotonic e.ref) || (@atomic :monotonic e.ref = true)`. It only writes when the bit is clear, so hot entries cause no writes at all.
- The CLOCK hand clears bits under the lock. Readers may set a bit while the hand clears it, which is benign.
- Because readers can keep re-setting bits, the sweep is bounded: after two sweeps without finding a clear bit, the hand evicts the entry under it.

The alternatives, if the bits stay in a vector:

- `Vector{UInt8}` with `unsafe_load`/`unsafe_store!(p, x, :monotonic)` works on 1.10. Orderings on these functions are supported since 1.10. It is safe because the elements are bits types, so no GC barrier is involved.
- `AtomicMemory` with `@atomic m[i]` needs 1.12. The type exists on 1.11, but the indexing syntax does not.
- `Threads.Atomic` per slot costs an allocation and an indirection per slot.
- UnsafeAtomics.jl is not needed, since Base's orderings cover this.

## Q4: consistent key/value pairs, reallocation, GC safety

In the current layout (parallel `keys`/`vals` vectors, `push!` growth, `_reuseslot!`, `_unsetindex!`), a lock-free reader could:

- read a reallocated (freed) buffer after a `push!`;
- see a null `Key{Any}` after `_unsetindex!`;
- pair the key of one entry with the value of the next entry in the reused slot.

Validating after the read catches the last case only, and only after the unsafe read has already happened. `ClockCache` avoids all three by construction:

- **One immutable `Entry` per key/value** (`key::Any`, `hash`, `val::V`, `size`, `pos` are all `const`; only `ref` is `@atomic`). A reader that loads an entry sees that entry's own key and value.
- **Tables never change length.** A table that would exceed half load (live entries plus tombstones) is replaced by a new one, published with `@atomic :release c.table = t`. Readers load the table with `:acquire` and keep using that one, so every index is in bounds.
- **Slot loads use `unsafe_load(pointer(t, i), :acquire)`** on `t::Vector{Any}`, under `GC.@preserve t`. The LLVM IR shows `load atomic … acquire` on 1.10, 1.11, 1.12 and 1.13, with 0 allocations.
- **Slot stores use ordinary `t[i] = x`.** It emits `store atomic … release` *and* the GC write barrier on all four versions, also verified in the IR.
  - Writing references through `unsafe_store!` or `atomic_pointerset` would skip the write barrier. The GC could then free a young entry stored into an old table, so that is never done.
- **Nothing is unset.** Removal stores `TOMBSTONE`, or `nothing` (see invariant 3), so readers never see an undefined slot.
- **Removed entries stay alive** while a reader holds them (a rooted local), and are collected afterwards. The "freed slots release their values" test passes for the new type.

## The final design

**Files:**

- `src/containers/clock.jl`: `ClockCache{K,V}`, the lock-free design. Its constructor, `show`, `cache_stats`, `resize!`, `delete!`, `empty!`, iteration and second-chance order are those of the locked design.
- `src/containers/localclock.jl`: `LocalClockCache{K,V}`, the previous locked `ClockCache`, internal. `_localtype` (`src/call.jl`) maps `TaskLocalCache{ClockCache}` (and `TaskLocalCache()` while `ClockCache` is the default container) to it. `TaskLocalCache{ClockCache{Any,Any}}` asks for the concrete type and gets the lock-free one.
- `src/containers/interface.jl`:
  - `get!` forwards to `_get!(default, c, p::Key)`, which containers implement, with the key already converted and hashed.
  - `default::F` forces specialization: without it, 1.10 boxed the closure on hits.
  - `IteratorSize = SizeUnknown()` fixes a pre-existing race. `collect(c)` sized its result with `length(c)` and then iterated a different snapshot, which threw `ArgumentError` under `-t 8`, for every container.
  - `_probe` (the key converted to `K`, or `nothing`) is shared by the `Dict`-indexed containers and `ClockCache`.
- **Tests:**
  - `test/test_containers.jl` runs the whole container suite on `LRU`, `ClockCache` and `LocalClockCache`.
  - `test/test_concurrency.jl`: 4×nthreads tasks mix `get!`/`get`/`setindex!`/`delete!`/`resize!`/`empty!`/iteration, on mixed key types (`Int`, 4-tuples, strings, vector-holding tuples), for count and size limits, on all three containers. Every returned value is checked against its key, and the stats are checked to be exact.
  - The same file has a hot-key reader test under constant table rebuilds, `empty!` and `resize!`, and checks that `@cached` hits through global and task-local `ClockCache`s are inferred and allocate 0 bytes, and that the task-local one is a `LocalClockCache`.
- **Benchmark:** `benchmark/contention.jl` compares `ClockCache`, the locked design shared ("locked Clock"), `LRU`, and task-local caches.

**Invariants a maintainer must keep** (also written in the source):

1. Entries are immutable apart from `ref`.
2. A published table is never resized or `push!`ed. Growth means building a new table and doing a release store into `c.table`.
3. In a published table a slot changes only, under the lock:
   - from `nothing` to an entry;
   - from an entry to `TOMBSTONE`;
   - from `TOMBSTONE` to an entry;
   - from either to `nothing` when the *next* slot is `nothing`, in which case no probe continues past it anyway.

   Entries never move, so a present key is always found. Without the trailing cleanup, steady churn rebuilt the table every 10k–20k misses; with it, `used` stays at about 1.1× the entry count.

**Local rules:**

- Writers store slots only with `setindex!`, never through pointers (GC barrier).
- Readers load only with `_loadslot` (acquire).
- Every ring entry is in the current table, since `_remove!` searches for it by identity.
- The table stays at most half full, so probes end.

**Semantic change.** A lookup that races with a mutation may return an entry that is being evicted, deleted or emptied at the same moment. A lookup during a rebuild may also see the previous table, and so miss a just-inserted key; that goes to the locked miss path, which checks again. The returned value always belongs to its key, and a task always sees its own writes. For memoization this is harmless.

**Risks:**

- **Memory model.**
  - The acquire load is a documented API: `unsafe_load` with an ordering, since 1.10.
  - The *release* half relies on `setindex!` of a reference into an `Array`/`Memory` compiling to `store atomic release`. Julia does this for memory safety, and I verified it on 1.10–1.13, but it is codegen behaviour, not documented API. A `Threads.atomic_fence()` before each store would make it independent of that at a small cost on misses.
- **x86 only measured.** On ARM the acquire/release pair is what makes it correct, and nothing relies on TSO. It is untested there, though.
- **Memory.** About 127 B per entry, against 103 B for the locked design (`summarysize`, 10k `Int=>Int` entries in `{Any,Any}`). Each miss allocates about 120 B, against about 75 B. Each cache has `64 × maxthreadid()` bytes of counters.
- **Misses are still serialized.** Each insertion takes the global lock and touches shared lines. With realistic (µs+) computations this matters much less than in the benchmark below, where computing costs nothing.

## Benchmarks

Setup:

- Machine: `ccqlin038`, 32 cores, shared. The load average was 5–17 during the runs, so the numbers are noisy.
- `benchmark/contention.jl`: one task per thread, 200k lookups per task, median of 7 runs, as ns per lookup within a task. Constant across thread counts means perfect scaling.
- All caches are `{Any,Any}`, as in `@cached`.
- "task-local" means one locked cache per task: uncontended, but every task fills its own.
- The 8- and 16-thread sweeps were run twice (values `a/b`). Lock-free hits agreed within about 15%, contended paths within about 20%.
- Julia 1.13.1 unless noted.
- The 16-thread rows were measured before the machine's users asked for runs of at most 8 threads, so they were not repeated after the final code changes. The last change touched only `const pos` and the tests.

In the tables below, `ClockCache` is the locked design (now `LocalClockCache`) and `LockFree` the current `ClockCache`; they were measured on the prototype, before the rename.

**Shared hits, `Int` keys (1k keys), ns/lookup:**

| threads | ClockCache | LockFree | Sharded(16) | Sharded(64) | task-local |
|-:|-:|-:|-:|-:|-:|
| 1 | 30.8 | **13.8** | 32.4 | 34.7 | 30.8 |
| 2 | 309 | **29** | 263 | 213 | 34 |
| 4 | 367 | **28** | 483 | 323 | 35 |
| 8 | 504/493 | **26/24** | 992 | 536/529 | 44/38 |
| 16 | 1002/1000 | **45/38** | 2130 | 1197/1270 | 64/46 |

**Shared hits, 4-tuple keys `(i, i%7, :leg, Float64(i))`, ns/lookup:**

| threads | ClockCache | LockFree | Sharded(16) | Sharded(64) | task-local |
|-:|-:|-:|-:|-:|-:|
| 1 | 39.2 | **24.0** | 41.3 | 43.9 | 39.6 |
| 2 | 397 | **39** | 262 | 232 | 43 |
| 4 | 439 | **38** | 478 | 351 | 42 |
| 8 | 556/639 | **31/29** | 934 | 553/556 | 66/48 |
| 16 | 1115/1239 | **45/36** | 1815 | 1168/1303 | 67/72 |

**One hot key shared by all threads**, where sharding cannot help:

| threads | ClockCache | LockFree | Sharded(64) | task-local |
|-:|-:|-:|-:|-:|
| 1 | 29.9 | **11.1** | 30.0 | 29.5 |
| 8 | 378/385 | **10.9/11.9** | 367/404 | 30.0 |
| 16 | 760/817 | **15.4/16.0** | 864/855 | 46.9/40.2 |

**Through `@cached`** (registry lookup, `CacheStyle`, `::V` assert; task-local includes the `task_local_storage` lookup):

| threads | Int: Clock | Int: LockFree | Int: task-local | 4-tuple: Clock | 4-tuple: LockFree | 4-tuple: task-local |
|-:|-:|-:|-:|-:|-:|-:|
| 1 | 36.3 | **19.7** | 63.3 | 54.0 | **39.1** | 74.3 |
| 2 | 453 | **28.6** | 68.5 | 606 | **40.0** | 74.4 |
| 4 | 354 | **29.1** | 70.8 | 380 | **42.4** | 76.7 |
| 8 | 538/550 | **28/32** | 87/72 | 793/763 | **43/41** | 114/99 |
| 16 | 1273/1081 | **46/32** | 111/103 | 1753/1467 | **76/51** | 148/120 |

All hit rows allocate 0 B per lookup for shared caches. Task-local rows show about 1.3 B per lookup from filling each task's cache.

**Mixed hit/miss workloads**, where the computation is trivial, so misses are pure insertion and eviction cost. ns/lookup, and B/lookup at 1 thread:

| workload | threads | ClockCache | LockFree | Sharded(16) | Sharded(64) | task-local |
|:-|-:|-:|-:|-:|-:|-:|
| Zipf 1.0, 100k keys, cap 10k | 1 | 92 (28 B) | **66** (35 B) | 82 | 94 | 76 |
| | 2 | 1030 | 620 | 244 | **211** | 90 |
| | 4 | 1591 | 1016 | 890 | **615** | 182 |
| | 8 | 2845/2928 | 2036/2050 | 1731 | **922/990** | 252/241 |
| | 16 | 6529/6335 | 3912/3980 | 4116 | **2410/2441** | 340/390 |
| uniform, 20k keys, cap 10k (~50% misses) | 1 | 145 (40 B) | **113** (62 B) | 139 | 151 | 137 |
| | 8 | 4027/4792 | 3777/3232 | 2025 | **1035/1048** | 414/391 |
| | 16 | 11786/11671 | 7649/7513 | 4930 | **2186/2193** | 476/475 |

**Experiment, not kept:** `ShardedCache` over lock-free shards (one-line change):

| workload | threads | 16 shards | 64 shards |
|:-|-:|-:|-:|
| hits, Int keys | 8 | 57 | 42 |
| hits, Int keys | 16 | 43 | 52 |
| Zipf | 8 | 738 | 452 |
| Zipf | 16 | 1412 | 624 |
| uniform | 8 | 1307 | 788 |
| uniform | 16 | 2874 | 1239 |

These are the best contended-miss numbers measured. The cost is per-shard budgets and per-shard counter arrays.

**Other runs:**

- **Julia 1.10.12**: hits at 1 thread are 43.8 ns for `ClockCache` and 14.9 ns for LockFree; `@cached` `Int` hits 52.0 and 22.3 ns. At 8 threads, `Int` hits are 2181 vs 26 ns, and `@cached` 2873 vs 31 ns. `ClockCache` contention is about 4× worse on 1.10.
- **A `Threads.SpinLock` in place of `ReentrantLock`** for the writer lock made contended misses *worse*: Zipf 2548 ns at 8 threads, 5140 ns at 16. It was reverted.
- **Single-thread BenchmarkTools** (`@belapsed`, 1.13): `Int` hits 30.1 → 13.5 ns, 4-tuple 37.8 → 23.2 ns. `LRU` is 33.2 and 41.7 ns.

**After the refactor** (final code, 1.13.1, load average about 5, ns/lookup):

| workload | threads | ClockCache | locked Clock | LRU | task-local |
|:-|-:|-:|-:|-:|-:|
| hits, `Int` keys | 1 | 13.5 | 30.9 | 34.6 | 30.9 |
| | 8 | 23.3 | 484 | 1084 | 34.9 |
| `@cached` hits, `Int` | 1 | 20.0 | 37.0 | 40.6 | 66.0 |
| | 8 | 28.1 | 529 | 1022 | 80.1 |
| `@cached` hits, 4-tuple | 1 | 40.4 | 53.5 | 58.2 | 74.9 |
| | 8 | 41.0 | 853 | 1844 | 104 |
| Zipf | 8 | 2086 | 2874 | 3955 | 223 |

## Follow-ups

1. **`AtomicMemory`, once 1.10 support is dropped** (or behind `@static VERSION >= v"1.12"`). The table can become `AtomicMemory{Any}` with `@atomic :acquire t[i]` / `@atomic :release t[i] = x`. That is the fully official API, removes the reliance on `setindex!` being a release store, and the pointer code (`_loadslot`, and the counters' `unsafe_load`/`unsafe_store!`) would go away.
2. **Shards of lock-free caches for miss-heavy shared workloads.** The experiment above gave 2–4× better contended misses, at the cost of per-shard budgets (one shard can fill while others are empty, and small limits cannot be honoured exactly) and per-shard counter arrays. Worth it only if such workloads matter in practice.
3. **One implementation for both.** The per-thread counter array could be sized by the caller (one 64-byte line for a task-local cache, which a single task updates exactly), which would let task-local caches use the lock-free `ClockCache` too and drop `LocalClockCache`; the price is about 25 B more per entry and 45 B more per miss.
