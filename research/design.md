# Design (v0.1)

Decisions for the rewrite, agreed on 2026-10-01.
Background and the rejected alternatives are in the other notes in this folder.
Items marked **open** still need a decision.

## Goals

- Replace TensorKit's internal `@cached` and the hand-rolled caches in SUNRepresentations.jl: `CGC_CACHE`, `REDUCED_CGC_CACHE`, `FCACHE`/`FUCACHE`.
- **Full type stability when it is available.** For a type-stable function called with concrete argument types, the call infers to the value type `V`, and a cache hit allocates nothing.
- **Full argument support**: any number of positional arguments, varargs, default values, and keyword arguments.
- **Precompilation-safe**: no `Core.eval`, no methods defined at runtime, no evaluation into other modules.
- **Small and maintainable.** All strategy logic is ordinary code in Cached, and the macro does only syntax rewriting.

## Non-goals for v0.1

- A disk-backed cache. A later extension will generalize SUNRepresentations' JLD2 + Scratch + Pidfile setup.
- A memory budget per process.

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
- **`GlobalCache{C}`** and **`TaskLocalCache{C}`**: `get!(cache, key) do implementation(...) end::V`, where `cache` is the function's single `C{Any,Any}`.
  - Revised on 2026-10-01, after the TensorKit integration. Each function originally had one typed sub-cache `C{K,V}` per key and value type. That bounded memory poorly: TensorKit reached about 50 sub-caches per function, and a single function's entries could exceed its limit by 100×.
  - Calls stay inferred because of the `::V` assertion, not because of the cache type. The lookup does not box the key either, thanks to the probe keys described under Containers.
  - Measured on `main` against this design: hits take the same time (35 vs 34 ns for `Int` keys; 126 vs 124 ns for TensorKit-like 4-leg tree keys), with zero allocation in both.
  - For `TaskLocalCache`, the table is stored in `task_local_storage()`. A `Dict` would box untyped keys, so it is still typed per key and value type.

## Containers

Cached provides its own containers, so it no longer depends on LRUCache.jl.
Both implement the same small interface: `get!`, `get`, `haskey`, `empty!`, `resize!`, `length`, and hit/miss statistics.

- **`LRU{K,V}`** is array-backed. It uses a `Dict` index, slots stored in vectors, and `prev`/`next` stored as integer vectors. Nodes are never allocated, and eviction is exact LRU.
- **The index is a `Dict{Key{Any},Int}`.** Each stored `Key{Any}` holds the key and its hash. Lookups probe it with a concretely typed `Key{K}`, whose `isequal` checks `s.key isa K` before comparing, so the comparison is static and the key is never boxed. A `Key{Any}` cannot serve as the probe: storing the key in an `Any` field boxes it (96 B per lookup on TensorKit-like keys).
  - This holds for `C{Any,Any}` as well, where a plain `Dict{Any,…}` would allocate on every hit.
  - Eviction never re-hashes, because the hash is stored.
  - Keys of different types are different entries, even when `isequal` (`f(3)` and `f(3.0)`). Lookups on a typed cache convert the key to `K` first.
- **`ClockCache{K,V}`** uses second-chance eviction: a ring of slots with a reference bit. A hit only sets the bit and never reorders the ring, which makes it cheap for read-heavy shared caches.
- Each container takes a size limit, either a **count** or **bytes** measured by a `by` function. Each one holds its own lock. Task-local containers skip the lock.
- **Default for `GlobalCache`: `ClockCache`.**
  - On synthetic workloads (`benchmark/containers.jl`), it beat `LRU` everywhere single-threaded (28 vs 32 ns for an all-hit lookup) and had a slightly better hit rate under Zipf access. Both were 1.5–3× faster than LRUCache.jl.
  - On the TensorKit and SUNRepresentations integration, the two were indistinguishable.
  - It stays the default because a hit only sets a bit, which makes lock-free hits possible.
- **open**: contention. With 8 threads, every container's per-lookup cost *rises* (all hits: about 50–75 ns, against 28–32 ns single-threaded), because every lookup takes the cache's single lock.
  Sharding by key hash, or lock-free reads for `ClockCache`, are the candidate fixes. `TaskLocalCache` is the workaround meanwhile.

## Limits

**One budget per function**: the `maxsize` of its single cache, as a count or in bytes, covering all signatures together. The default is 10,000 entries, the same as TensorKit's caches before.

```julia
set_cache_size!(f, n; by = nothing)
```

The earlier per-sub-cache limit, the cap on the number of sub-caches (`maxsubcaches`, `set_max_subcaches!`) and the first-in-first-out dropping of whole sub-caches are gone.

Defaults come from Preferences (below).

## Registry and introspection

- Caches are created at runtime, on the first call of each function. There is one per function, or one per container type if its `CacheStyle` selects several. Nothing is registered at load time.
- **Lookups take no lock.** The hot path reads an immutable snapshot of an `IdDict` through an atomic field. Creating a cache rebuilds the snapshot under a lock, which is rare: it happens once per function.
- **The lookup key is a constant type** when `f` is a singleton function: `Tuple{typeof(f), C{Any,Any}}`. Its hash is cached, so the lookup is cheap. Callable objects with fields fall back to an `(f, C)` tuple key, so each distinct instance gets its own cache.
- `cache_info([f])` returns the live caches as `f => cache` pairs. Containers `show` as a one-line summary (type, size against the limit, hits, misses), so no separate summary type is needed, and the pairs can be emptied or resized directly. Container iteration walks a snapshot taken under the lock, so it is thread-safe.
- `empty_caches!()` empties every cache, and `empty_caches!(f)` empties the caches of `f`.
- Task-local tables are not visible to `cache_info`. **open**: whether that matters.

## Configuration

Decided on 2026-10-01: per package **and** per function, through Preferences.jl. The full description is in `docs/src/configuration.md`.

- Settings are `maxsize` and `measure` (`"count"` or `"bytes"`, the latter using `Cached.cachesize`).
  - They are resolved once per function, when its first cache is created, in this order: runtime calls, then `[<Package>.Cached.<function>]`, then `[<Package>.Cached]`, then `[Cached]`, then the built-in defaults.
  - `<Package>` is the package of `parentmodule(typeof(f))`. For functions extended by several packages, that is the owner of the function, not the extending packages.
  - Reading them at runtime means they cost nothing at compile time and need no recompilation of user packages. Task-local caches use the same settings.
- `container` (`"ClockCache"` or `"LRU"`) is a compile-time preference, `[Cached]` only, because it selects the default `CacheStyle`, which must be a constant.
- `set_cache_preferences!` writes any of these sections, choosing the section from its argument: nothing for `[Cached]`, a package module, or a function. It merges with the existing tables, and a value of `nothing` removes a setting.
- `measure = "bytes"` uses `Cached.cachesize(x)`, which defaults to `Base.summarysize` and is meant to be overloaded per value type.

## Hooks and extensions

- **Instrumentation hook**: lookups and misses go through `Cached.instrument(f, phase, thunk)`, which by default is just `thunk()`.
  - A compile-time Preference switch removes the hook entirely when it is off.
  - `CachedTimerOutputsExt` implements the hook with TimerOutputs, which replaces TensorKit's `@timeit_debug` sections.
  - Packages label their functions by overriding `Cached.instrument_label(f, phase)`.
- **`CachedTachikomaExt`**: a TUI for browsing caches, watching hit rates live, resizing, and emptying.
- **Disk extension**: deferred. See non-goals.

## Open questions

- ~~**Functors**~~: resolved. The instance is passed to `implementation`, and instances with fields get their own cache, so the budget applies per instance.
- **Revise**: should redefining a cached method empty that function's caches?
- ~~**Inference**~~: resolved. `return_type` is the default for unannotated functions, falling back to `Any` when the result is not concrete. It folds at compile time, so a hit is fully inferred and allocates nothing.
