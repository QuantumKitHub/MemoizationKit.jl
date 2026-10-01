# Cache management

## Sizing

The prototype used two modes, both built on LRUCache.jl's `by` function:

- **Count-based**: `by = _COUNT_BY`, where `const _COUNT_BY = Returns(1)` is a sentinel.
  Testing `lru.by === _COUNT_BY` was how the code told the two modes apart, which is cheap but a hack.
- **Byte-based**: `by = Base.summarysize` by default, replaceable through `GLOBALCACHE_SIZE_FUNCTION[] = sizeof`.

The defaults were 64 GiB byte-based, or 10 000 entries in count mode.

Lessons:

- `Base.summarysize` on **every insert** is expensive for large nested values and can easily cost more than the computation it caches.
- A 64 GiB default per signature is effectively unbounded, and the total across caches was never bounded.
  A process-wide memory budget may be what users actually want.
- Switching an existing LRU between count and byte mode means emptying it, because the stored sizes become meaningless.

## Runtime API

```julia
set_cache_size!(f, 10_000)                         # count-based, all caches of f
set_cache_bytesize!(f, 500_000_000; by = sizeof)   # byte-based, clears entries
empty_globalcaches!()                              # clear all (also resets hit/miss counters)
caches_for(f)                                      # the LRU objects for f
global_cache_info()                                # summary table
```

Missing pieces:

- per-function `empty!`
- hit/miss reset independent of clearing
- task-local caches, which none of these functions touch

## Preferences

The defaults were loaded from `LocalPreferences.toml` at module load time, through `@load_preference("globalcache_bytesize")` and `@load_preference("globalcache_size")`.
`set_default_cache_bytesize!` wrote them and needed a restart to take effect.

The open question is whose preferences these should be.
Preferences are keyed on the package that calls `@load_preference`, so as written they configure *Cached.jl itself*, globally, for all downstream packages.
Per-package defaults, for example "TensorKit's caches default to 2 GiB", would need the macro to call `@load_preference` inside the user's module.

## Registry

There were three iterations:

1. `GLOBAL_CACHES::IdDict{Function, LRU{Any,Any}}`.
2. `PER_SIG_CACHES::Dict{String, Any}` (signature string to LRU), plus `_FUNC_TO_SIG_KEYS::IdDict{Function, Vector{String}}`.
3. `GLOBAL_CACHE_TABLE::IdDict{Function, IdDict{Type, Any}}` (function, then concrete argument type, then LRU), plus `_REGISTERED_STATIC_SIGS::Set{String}` for duplicate detection.

The registry has two jobs that are worth keeping separate: **introspection** (list everything, with stats) and **duplicate detection** (at macro evaluation time).

Precompilation caveat: a registry that is mutated at top level by downstream modules only contains entries from modules loaded in the *current* session.
For precompiled packages, registration has to happen in `__init__`, or the registry has to be reconstructed from the module's consts.

## Introspection output

`global_cache_info()` printed a box-drawn table:

```
Cache Usage Summary (2 caches)
┌──────────────┬──────┬────────┬──────────┬──────┬───────────────────┐
│ Signature    │ Hits │ Misses │ Hit rate │ Fill │ Memory            │
├──────────────┼──────┼────────┼──────────┼──────┼───────────────────┤
│ expensive(…) │ 1234 │     56 │    95.7% │   42 │  3.2 MB / 64.0 GB │
└──────────────┴──────┴────────┴──────────┴──────┴───────────────────┘
```

In byte mode, Fill shows the entry count and Memory shows `current / max`.
In count mode, Fill shows `current/max` and Memory shows `summarysize(lru)`.
This was hand-rolled with `Printf`. Consider instead a `show` method on a returned `CacheInfo` vector, which can be consumed programmatically and also prints nicely.
