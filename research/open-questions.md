# Pitfalls and open questions

## Bugs in the archived WIP (`0510573`)

These are recorded so the same mistakes are not repeated:

- `_cached_tasklocal_def` uses a literal `D` and `Dvar()` inside the quote instead of interpolating `$Dvar`, assigns to `cache` but reads `$cachevar`, and uses `d.arg.name`, which is not a field of `Expr`.
- `_cached_global_def` calls `_sig_string`, which only existed in the previous revision.
- `src/try.jl` is a scratch version of the macro that refers to undefined names.
- In `3d11e28`, an untyped signature's key used the *argument name*: `f(x)` became `"f(x)"`, so `@cached f(x)` followed by `@cached f(y)` was not detected as a duplicate.

## Semantics

- **Key equality is `isequal`/`hash`**, so `f(3)` and `f(3.0)` share an entry and can return the wrong type.
  Should keys include the type, as in `(typeof(x), x)`, or should the cache be per concrete type, as approach 4 does?
- **Mutable keys**: an array that is mutated after being used as a key corrupts the cache silently.
  Options: document it, `deepcopy` keys, or refuse mutable keys under some trait.
- **Returned values are shared**: mutating a cached result mutates the cache.
  TensorKit relies on callers not doing this.
- **Revise or redefinition**: redefining the body does not invalidate entries.
  Could the world age or method instance be tracked, or should redefinition just empty that function's caches?
- **Recursion**: a cached function that calls itself (memoized Fibonacci) re-enters `get!` on the same LRU.
  Check whether LRUCache.jl holds its lock while running the default function; if it does, that deadlocks or serializes.
- **Exceptions in the body** must not leave a half-inserted entry.

## Concurrency

- `GlobalLRUCache` relies on LRUCache.jl's internal lock. Under heavy multithreading this is a contention point, which is why `TaskLocalCache` exists.
- Task-local caches are **unbounded, invisible to introspection, and die with the task**.
  Any `Threads.@spawn`-heavy code rebuilds them constantly.
- Is a **sharded or per-thread** cache worth adding as a fourth style? Note that `threadid()` is not stable for a task in recent Julia.
- The task-local storage key was `Symbol(:_tasklocal_, parentmodule(f), :_, nameof(f), :_cache)`, which collides for functions with the same name in modules with the same name, and for closures.

## Macro and API design

- **Strategy as the first argument** (`f(::NoCache, x)`) puts extra methods on the user's function.
  With multiple arguments, the wrapper `f(a, b)` and the implementation `f(::NoCache, a)` have the same arity and can clash.
  TensorKit puts the strategy last, which has the mirror-image problem.
  Alternatives are an underscored implementation function (`_f`), or a single internal entry point `Cached.call(style, f, args...)` that keeps `f`'s method table clean.
- **Keyword arguments and default values**: users will ask for them.
  Defaults are easy: expand to the full-arity call before the wrapper.
  Kwargs need a key policy, such as sorting into a `NamedTuple`.
- **Multiple arguments**: the first version supported tuple keys and the last one dropped them.
  Is single-argument plus "pack it into a key struct" (TensorKit's `FSPBraidKey` style) a reasonable rule, or too restrictive?
- **Return type annotation** as the source of `V`: required, optional, or inferred?
- **Duplicate registration**: is it an error or a warning? Revise users will hit it constantly.
- **Profiling hooks**: TensorKit wraps lookups and misses in `@timeit_debug`.
  Should Cached.jl provide a hook, such as a callback or an extension on TimerOutputs, so packages don't lose that?

## Precompilation and load time

- Must `@cached` inside a precompiled package produce caches that work after loading, with correct types and registered for introspection?
  This rules out `Core.eval` into foreign modules and runtime method definition.
- Should `@cached` definitions be invalidation-free for downstream code?
- How should the dependency footprint be kept minimal? LRUCache and Preferences are light, but Printf was only there for the table.

## Scope questions to settle first

1. Is the primary consumer the TensorKit ecosystem, or general-purpose memoization?
2. Is matching TensorKit's `CacheStyle` API exactly, so that it can be a drop-in replacement, a hard requirement?
3. How much does typed-cache performance actually matter versus `LRU{Any,Any}` plus a return assertion? Benchmark before building machinery.
