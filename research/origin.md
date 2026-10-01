# Origin

The prototype was an extraction and generalization of the `@cached` macro that TensorKit.jl uses internally (`src/auxiliary/caches.jl`).
TensorKit uses it for fusion-tree manipulations (`fsbraid`, `fstranspose`, tree transformers) and space structure, where the same expensive symbolic computation is repeated many times with identical keys.

## What TensorKit's version does

```julia
@cached function fsbraid(key::K)::_fsdicttype(K) where {I, N₁, N₂, K <: Union{FSPBraidKey{I, N₁, N₂}, FSBBraidKey{I, N₁, N₂}}}
    ...
end

CacheStyle(::typeof(fsbraid), k::Union{FSPBraidKey{I}, FSBBraidKey{I}}) where {I} =
    FusionStyle(I) isa UniqueFusion ? NoCache() : GlobalLRUCache()
```

It generates:

- `_fsbraid(args...)` — the user's body, under an underscored name.
- `fsbraid(args...)` — calls `fsbraid(args..., CacheStyle(fsbraid, args...))`.
- `fsbraid(args..., ::NoCache)` — calls `_fsbraid` directly.
- `fsbraid(args..., ::TaskLocalCache{D})` — looks up a `D` in `task_local_storage()` under `:_tasklocal_fsbraid_cache`.
- `fsbraid(args..., ::GlobalLRUCache)` — uses `const GLOBAL_FSBRAID_CACHE = LRU{Any,Any}(; maxsize = DEFAULT_GLOBALCACHE_SIZE[])`, pushed onto `GLOBAL_CACHES`.

It also wraps the lookup and the miss path in `@timeit_debug` sections, labeled "bookkeeping" or "symmetry", so cache costs show up in TimerOutputs profiles.

Notable details:

- **The strategy goes last** (`f(args..., ::Style)`), not first as in the prototype.
- **The return type can depend on where-parameters** (`_fsdicttype(K)`), so the value type is not known at macro-expansion time.
  This is the main reason the prototype kept reworking how the typed LRU gets created (see [global-cache-binding.md](global-cache-binding.md)).
- **`CacheStyle` is a per-argument decision**, not just per function: for abelian symmetries it is cheaper to recompute than to hash.
- **Every cache is `LRU{Any,Any}`**, so lookups are type-unstable and rely on the return type assertion.

## What the prototype was trying to fix

1. Make it reusable outside TensorKit, for TensorKitSectors, MPSKit, and others, without each package copying the macro.
2. Get **concretely typed caches** so lookups are type-stable without relying only on return-type assertions.
3. Add **memory-aware sizing**, measuring bytes as well as counting entries, because fusion-tree caches can grow very large.
4. Add **better introspection**: a summary table, per-function resizing, and clearing.
5. Keep **precompilation safety**, which TensorKit needs.

Point 2 conflicts with point 5 whenever the value type depends on runtime types.
Resolving that conflict is the central design problem.

## Prior art in the General registry

Look at these again before redesigning:

- **Memoize.jl** — `@memoize`, with a custom dict type per function. Supports kwargs. Caches live in a global per method.
- **Memoization.jl** — `@memoize`, with a configurable cache type and per-function `empty_cache!`. Handles closures.
- **LRUCache.jl** — the thread-safe LRU the prototype used. It provides `cache_info`, a `by` size function, and `resize!`.
- **Caching.jl**, **CachedFunctions.jl**, **CachedCalls.jl** — smaller variants worth skimming for API ideas.

None of them offers *per-call-site strategy dispatch* (`CacheStyle`) or task-local caches.
Those are the distinctive features.
