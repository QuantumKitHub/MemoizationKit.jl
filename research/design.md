# Design

The decisions behind Cached.jl and the invariants the code relies on. User-facing details are
in `docs/src`; the prototype notes in this folder hold the rejected alternatives.

## Goals

- Replace TensorKit's internal `@cached` and the hand-rolled caches of SUNRepresentations.jl.
- Type stability: a type-stable function called with concrete arguments infers to its value
  type, and a cache hit allocates nothing.
- Full argument support: positional, default, varargs and keyword arguments.
- Precompilation-safe: no `Core.eval` or runtime method definitions in the call path.
- Small and maintainable: the macro only rewrites syntax; all logic is ordinary code.

Non-goal: a memory budget per process.

## Macro

`@cached` moves the body into `Cached.implementation(::typeof(f), args...; kw...)`, with
defaults removed, and leaves `f` with its original signature calling
`Cached.call(f, CacheStyle(f, args...), V, args, kw)`. Julia's lowering handles defaults and
keywords, and dispatch on `typeof(f)` covers qualified names, operators and callable objects.

- `cachekey(f, args...; kw...)` defaults to the tuple of positional arguments, plus the
  keyword `NamedTuple` if any. Custom keys can merge calls of different argument types or
  methods; those calls must admit the same result, including its return type. Computation
  and strategy selection still use the original arguments.
- `Hashed(value, hashf, eqf)` supplies custom hashing and equality without redefining them
  on the input type. Wrappers require identical hash and equality callables (`===`) to
  compare equal. Canonical keys can also merge disk entries; wrapper equality alone cannot,
  because disk caching compares serialized bytes.
- `V` is the return annotation, or `Core.Compiler.return_type` of `implementation`, falling back
  to `Any` when not concrete. The result is asserted `::V`, which keeps calls inferred.

## Strategies

`CacheStyle(f, args...)` picks `NoCache`, `GlobalCache{C}` or `TaskLocalCache{C}` per function
and argument type; the default is `GlobalCache()`, whose container is the compile-time
`container` preference (`ClockCache`). `DiskCacheStyle` (below) is independent of it.

- Each function has **one** global `C{Any,Any}` cache, which is its memory budget. Typed
  sub-caches per signature bounded memory poorly (TensorKit reached ~50 per function).
- Task-local caches live in `task_local_storage()` and are not registered.

## Containers

- The public `AbstractCache` interface is only what the machinery calls (`docs/src/interface.md`).
  `AbstractCache <: AbstractDict` is kept so `LRU` and `ClockCache` stay dictionaries.
- `LRU` and `ClockCache` share an internal `SlotCache` implementation on a `Slots` field and
  differ only in four eviction hooks (`admit!`, `touch!`, `victim`, `forget!`).
- The index is a `Dict{Key{Any},Int}` holding each key with its hash; lookups probe with a
  concrete `Key{K}` whose `isequal` checks the type first, so hits never box the key. Keys of
  different types are different entries (`f(3)` and `f(3.0)`).
- One lock per cache; `get!` computes outside it, so functions may recurse into their own cache.
- Lock contention on shared caches with cheap keys is real in microbenchmarks but did not show in
  TensorKit's workloads. Lock-free `ClockCache` hits are parked on the `lockfree-clock` branch
  (#9); `TaskLocalCache` is the workaround.

## Registry

Caches are created on a function's first call. The hot path reads an immutable `IdDict`
snapshot through an atomic field, without locking; creating a cache republishes the snapshot
under a lock. For singleton functions the lookup key is a constant type, so its hash is cached.

## Configuration

`maxsize` and `measure` (and the disk settings) come from Preferences.jl, resolved once per
function at runtime: runtime calls, then `[<Package>.Cached.<f>]`, `[<Package>.Cached]`,
`[Cached]`, built-in defaults. `<Package>` owns `parentmodule(typeof(f))`. Only `container` is
compile-time. See `docs/src/configuration.md`.

## Extensions

- **Timing** (`CachedTimerOutputsExt`, `docs/src/timing.md`). Calls go through an internal
  `instrument(f, phase, thunk, ::Val{owner})` that compiles to `thunk()`. Enabling a package
  evals one method for its owner tuple into the extension (recompiling only its callers);
  disabling deletes it. Enabling first deletes any existing method, since deleting an
  overwriting method revives the old one. The owner is computed outside the closures:
  otherwise Julia 1.10 boxes them.
- **Dashboard** (`CachedTachikomaExt`, `docs/src/dashboard.md`). Renders from copied statistics,
  never holding a cache lock across frames. Tabs for RAM and disk; the Disk tab uses in-memory
  counters, and reads entries and sizes (`disk_cache_info`) in a background task, never on a
  frame. Emptying and resizing act on RAM only.
- **Disk** (`CachedSQLiteExt`, `docs/src/disk.md`). Below RAM: RAM, then artifact, then the
  node's SQLite database, then compute. One WAL-mode database per function, version and host,
  shared by the node's processes. `diskversion(f)` is the only version: keeping stored results
  valid (including across Julia versions) is the user's responsibility. Functions without a
  disk style compile exactly as before.
- Each extension's entry points are stubs in the core with an error hint.

## Open questions

- Should redefining a cached method (Revise) empty its caches?
