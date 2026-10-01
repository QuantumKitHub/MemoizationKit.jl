# How the global method finds its cache

The `GlobalLRUCache` method must reach an LRU object.
How it gets that reference controls type stability, precompilation safety, and lookup cost.
The prototype tried four approaches.

## 1. One `LRU{Any,Any}` per function, behind a lookup (`c683263`)

```julia
const GLOBAL_CACHES = IdDict{Function, LRU{Any,Any}}()
_global_cache(f) = GLOBAL_CACHES[f]

f(::GlobalLRUCache, args...) = get!($(_global_cache)(f), (args...)) do ... end
```

- ✅ Precompilation-safe: no live objects embedded in code.
- ❌ An `IdDict` lookup on every call, plus type-unstable keys and values.
- ❌ All signatures of `f` share one cache.

## 2. One typed `const` per signature (`3d11e28`, the `@cached` default)

```julia
const _cached_f__Int = _make_typed_global_lru(Int, Float64)   # K, V from the macro
f(::GlobalLRUCache, x::Int) = get!(_cached_f__Int, x) do ... end::Float64
_register_per_sig_cache!("f(::Int)", _cached_f__Int, f)
```

- ✅ Precompilation-safe. The const binding resolves to a direct pointer, with no lookup.
- ✅ Typed when the signature is concrete.
- ❌ `K` and `V` must be known **at macro-expansion time**. They fall back to `Any` when the argument type mentions a where-parameter, or when the return type is computed (`_fsdicttype(K)`), which is exactly the TensorKit use case.
- ❌ The const name is derived from the type expression as a string, so it can collide and is ugly.

## 3. Embed the LRU by value with `Core.eval` (`@cached_direct`, mentioned in `3d11e28`)

The LRU object is spliced directly into the method body as a literal, which makes it a true closure.

- ✅ The cheapest possible lookup.
- ❌ Not precompilation-safe, because a serialized method would point at an object that only existed in the precompile process. Usable only in the REPL or in scripts.

## 4. Lazy per-concrete-type LRU, specialized on first call (`0510573`, WIP)

```julia
function f(s::GlobalLRUCache, x)                          # generic fallback
    lru = _ensure_global_lru!(f, typeof(x), V)            # GLOBAL_CACHE_TABLE[f][T]
    _eval_global_method!(f, typeof(x), lru, @__MODULE__)  # Core.eval f(::GlobalLRUCache, ::T) with lru embedded
    return Base.invokelatest(f, s, x)
end
```

- ✅ Each concrete argument type gets its own `LRU{T,V}`, so keys are concrete.
- ✅ After the first call, the lookup is as cheap as approach 3.
- ❌ Not precompilation-safe. It also evals into *other people's modules* at runtime, which fails if that module is closed (precompiled packages) and is generally hostile.
- ❌ Every first call for a new type defines a method, which **invalidates** callers and requires `invokelatest`. The extra world-age hop runs on the first call for each type.
- ❌ `V` still comes only from the annotation, so it is not truly typed when the return type depends on `T`.
- ❌ The specialized method dropped the return-type assertion.

## Ideas not tried yet

- **Lookup keyed on the type**, without method definition. Generate `f(::GlobalLRUCache, x::T) where T = get!(_cache_for(f, T), x)`, where `_cache_for` is a `@generated` function or a `Base.@assume_effects :foldable` lookup in a `const` table. Done right, the compiler could fold the table access per `T`. Precompile behaviour still needs investigating.
- **A `const` cache container per function** holding `Dict{Type, LRU}` with a function barrier: `_lookup(lru::LRU{K,V}, x::K)::V`. One dynamic dispatch per call, but no codegen at runtime and fully precompilable.
- **Compute `V` with `Core.Compiler.return_type(f, Tuple{NoCache, T})`** at cache creation instead of requiring an annotation. This has the usual caveats about relying on inference results, and should probably be an opt-in.
- **Let the user name the cache type** in the macro, for example `@cached LRU{Key,Val}(maxsize=1000) function f(x) ... end`, or with a `CacheStyle` that carries the container, and skip inference entirely.
- **Store the cache in a callable struct** instead of adding methods to `f`. For example, `const f = CachedFunction(_f_impl, LRU{K,V}())` keeps the cache in a field, so it is type-stable and precompilable for free. The cost is that `f` becomes a struct rather than a generic function, which changes how users extend it.
