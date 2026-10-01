# Design (v0.1)

Decisions for the rewrite, agreed on 2026-10-01.
Background and the rejected alternatives are in the other notes in this folder.
Items marked **open** still need a decision.

## Goals

- Replace TensorKit's internal `@cached` and the hand-rolled caches in SUNRepresentations.jl: `CGC_CACHE`, `REDUCED_CGC_CACHE`, `FCACHE`/`FUCACHE`.
- **Full type stability when it is available.** For a type-stable function called with concrete argument types, the cache is a concretely typed `C{K,V}` and the call infers to `V`.
- **Full argument support**: any number of positional arguments, varargs, default values, and keyword arguments.
- **Precompilation-safe**: no `Core.eval`, no methods defined at runtime, no evaluation into other modules.
- **Small and maintainable.** All strategy logic is ordinary code in Cached, and the macro does only syntax rewriting.

## Non-goals for v0.1

- A disk-backed cache. A later extension will generalize SUNRepresentations' JLD2 + Scratch + Pidfile setup.
- A memory budget per function or per process.
- Grouping sub-caches by method signature.

## Macro expansion (approach C)

The user's body moves into a method of a function that Cached owns, dispatching on `typeof(f)`.
The user's own `f` keeps its exact signature, so Julia's lowering handles default values and keywords.

```julia
@cached function f(a::A, b::B = b0; k = 1)::R where {T}
    body
end
```

expands to approximately:

```julia
function Cached.implementation(::typeof(f), a::A, b::B; k) where {T}   # defaults removed; kwarg made required
    body
end

function f(a::A, b::B = b0; k = 1) where {T}                           # user signature, verbatim
    return Cached.call(f, CacheStyle(f, a, b), R, (a, b), (; k))::R
end
```

- The key is always the tuple of positional arguments, with the keyword `NamedTuple` appended when there are keywords. So `K = Tuple{typeof.(args)..., typeof(kwargs)}`.
- **`V`** is the return annotation when there is one. It is evaluated inside the method, so it may depend on `where` parameters, as `_fsdicttype(K)` does. Without an annotation, `Cached.call` uses `Core.Compiler.return_type` on `implementation` and falls back to `Any` when the result is not concrete.
- **`Cached.uncached(f, args...; kw...)`** calls `implementation` directly. It replaces the old `f(NoCache(), x)`.
- **Qualified names, operators, and functors** all work the same way, because dispatch is on `typeof(f)`. Examples are `TensorKitSectors.Fsymbol`, `Base.:*`, and `(x::Foo)(y)`.
- **Duplicate `@cached` on the same method** is no longer a separate concern. It is ordinary method overwriting, which Julia already reports, so no registry check is needed.

## Strategies

These keep TensorKit's names:

```julia
abstract type CacheStyle end
struct NoCache <: CacheStyle end
struct TaskLocalCache{C} <: CacheStyle end    # C: a cache container type, or an AbstractDict
struct GlobalCache{C} <: CacheStyle end
const GlobalLRUCache = GlobalCache{LRU}

CacheStyle(f, args...) = GlobalLRUCache()     # default; users specialize per function and argument type
```

`CacheStyle` only sees positional arguments, because keywords do not take part in dispatch.

`Cached.call` has one method per strategy:

- **`NoCache`**: calls `implementation(f, args...; kw...)`.
- **`GlobalCache{C}`** and **`TaskLocalCache{C}`**: first `sub = subcache(table, f, C, K, V)::C{K,V}`, then `get!(sub, key) do implementation(...) end`.
  - The type assertion after the untyped table lookup is SUNRepresentations' `FCACHE` pattern. It makes everything after the lookup type-stable, at the cost of one hash lookup on `(K, V)` per call.
  - For `TaskLocalCache`, the table is stored in `task_local_storage()`.

## Containers

Cached provides its own containers, so it no longer depends on LRUCache.jl.
Both implement the same small interface: `get!`, `get`, `haskey`, `empty!`, `resize!`, `length`, and hit/miss statistics.

- **`LRU{K,V}`** is array-backed. It uses a `Dict{K,Int}` index, `Vector{K}`/`Vector{V}` slots, and `prev`/`next` stored as integer vectors. Nodes are never allocated, and eviction is exact LRU.
- **`ClockCache{K,V}`** uses second-chance eviction: a ring of slots with a reference bit. A hit only sets the bit and never reorders the ring, which makes it cheap for read-heavy shared caches.
- Each container takes a size limit, either a **count** or **bytes** measured by a `by` function. Each one holds its own lock. Task-local containers skip the lock.
- **Default for `GlobalCache`: `ClockCache`**, tentatively.
  On synthetic workloads (`benchmark/containers.jl`), it beat `LRU` everywhere single-threaded, 28 vs 32 ns for an all-hit lookup, and had a slightly better hit rate under Zipf access.
  Both were 1.5–3× faster than LRUCache.jl.
  Confirm this on real TensorKit and SUNRepresentations workloads once the macro exists.
- **open**: contention. With 8 threads, every container's per-lookup cost *rises* (all hits: about 50–75 ns, against 28–32 ns single-threaded), because every lookup takes the cache's single lock.
  Sharding by key hash, or lock-free reads for `ClockCache`, are the candidate fixes. `TaskLocalCache` is the workaround meanwhile.

## Limits

There are only two:

1. **Per sub-cache**: each `C{K,V}` has its own `maxsize`, as a count or in bytes.
2. **Sub-caches per function**: a cap on how many distinct `(K, V)` sub-caches a function may hold.
   When a new key type would exceed the cap, the oldest sub-cache is emptied and dropped, first in, first out. **open**: confirm FIFO, rather than least recently used, for this.

```julia
set_cache_size!(f, n; by = nothing)   # sets the limit for every sub-cache of f, current and future
set_max_subcaches!(f, n)
```

Defaults come from Preferences (below).

## Registry and introspection

- Sub-caches are created at runtime, on the first call for each `(f, C{K,V})`. Nothing is registered at load time.
- **Lookups take no lock.** The hot path reads an immutable snapshot of an `IdDict` through an atomic field. Creating a sub-cache rebuilds the snapshot under a lock, which is rare: it happens once per function and key/value type.
- **The lookup key is a constant type** when `f` is a singleton function: `Tuple{typeof(f), C{K,V}}`. Its hash is cached, so the lookup costs about 7 ns on top of the container's `get!`, against about 35 ns for a `(f, C{K,V})` tuple key. Callable objects with fields fall back to the tuple key, so each distinct instance gets its own sub-caches.
- `cache_info([f])` returns the live caches as `f => cache` pairs, oldest first. Containers `show` as a one-line summary (type, size against the limit, hits, misses), so no separate summary type is needed, and the pairs can be emptied or resized directly. Container iteration walks a snapshot taken under the lock, so it is thread-safe.
- `empty_caches!()` empties every cache, and `empty_caches!(f)` empties the caches of `f`.
- Task-local tables are not visible to `cache_info`. **open**: whether that matters.

## Configuration

- Defaults are read through Preferences: sub-cache size, count or bytes mode, the sub-cache cap, and the container type.
- **open**: whether these are keyed per calling package, which would require the macro to load preferences in the user's module, or only on Cached.

## Hooks and extensions

- **Instrumentation hook**: lookups and misses go through `Cached.instrument(f, phase, thunk)`, which by default is just `thunk()`.
  - A compile-time Preference switch removes the hook entirely when it is off.
  - `CachedTimerOutputsExt` implements the hook with TimerOutputs, which replaces TensorKit's `@timeit_debug` sections.
  - Packages label their functions by overriding `Cached.instrument_label(f, phase)`.
- **`CachedTachikomaExt`**: a TUI for browsing caches, watching hit rates live, resizing, and emptying.
- **Disk extension**: deferred. See non-goals.

## Open questions

- ~~**Functors**~~: resolved. The instance is passed to `implementation`, and instances with fields get their own sub-caches. The per-function sub-cache cap therefore applies per instance.
- **Revise**: should redefining a cached method empty that function's caches?
- ~~**Inference**~~: resolved. `return_type` is the default for unannotated functions, falling back to `Any` when the result is not concrete. It folds at compile time, so a hit is fully inferred and allocates nothing.
