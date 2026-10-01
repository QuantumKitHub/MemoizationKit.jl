# Prototype architecture

## Strategy dispatch

The core idea is to decide *how* to cache at call time, through a trait that users can specialize:

```julia
abstract type CacheStyle end
struct NoCache <: CacheStyle end
struct TaskLocalCache{D <: AbstractDict} <: CacheStyle end
struct GlobalLRUCache <: CacheStyle end

CacheStyle(args...) = GlobalLRUCache()   # default
```

Users override it per function and per argument type:

```julia
Cached.CacheStyle(::typeof(expensive), ::BigMatrix) = NoCache()
Cached.CacheStyle(::typeof(expensive), ::ThreadSafeKey) = TaskLocalCache{Dict{Any,Any}}()
```

They can also bypass dispatch explicitly with `expensive(NoCache(), x)`.

Because `CacheStyle` is a pure function of types in the common case, the compiler can constant-fold it and the dispatch costs nothing.

## Generated methods

`@cached function f(x::T)::R where {T} body end` produced four methods:

| Method | Role |
|:-|:-|
| `f(x)` | dispatch wrapper: `f(CacheStyle(f, x), x)::R` |
| `f(::NoCache, x)` | the user's body, verbatim |
| `f(::TaskLocalCache{D}, x)` | `get!(get!(D, task_local_storage(), key), x) do f(NoCache(), x) end::R` |
| `f(::GlobalLRUCache, x)` | `get!(lru, x) do f(NoCache(), x) end::R` |

The return-type annotation is optional.
When present, it is asserted at every entry point, which matters because the global LRU tends to be `Any`-valued.

## Macro parsing

`splitdef` peeled off the three optional layers of a function head in order:

```
function f(args...) where {P...} :: ReturnType
          ↑ :call    ↑ :where      ↑ ::(2-arg)
```

(In the AST the `where` is outermost, then the `::`, then the `:call`.)

Argument forms handled were `x`, `x::T`, `::T` (with a gensym'd name), and in the first version also `x...` and `x::T...`.
Multi-argument keys were `(args...)` tuples, and single-argument keys were the bare argument.

Rejected outright:

- keyword arguments
- default argument values

The reason is that the generated wrapper methods would multiply the defaults, and kwargs would need to become part of the key.

The last iteration also restricted the macro to **single-argument functions**.
This was partly to simplify typed LRU inference and partly because of an arity clash: see "strategy as first argument" in [open-questions.md](open-questions.md).

## Duplicate registration

Each `(function, signature)` could be `@cached` only once.
Registering it again errors, because a second `@cached` would silently replace the methods while leaving a stale cache registered.
Detection was keyed on a signature *string* such as `"f(::Int)"`, which has its own problems (see open questions).

## Things that worked well

- The strategy trait is the right abstraction. It covers "don't cache trivially cheap keys", "cache per task to avoid lock contention", and "share globally" with one mechanism.
- Asserting the return type at every entry point kept call sites inferable even with `Any`-valued caches.
- Embedding helper functions by value in generated code (`$(_tasklocal_key)(f)` rather than `Cached._tasklocal_key`) made the macro work regardless of what the calling module imported.
