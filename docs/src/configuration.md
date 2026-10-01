# Configuration

```@meta
CurrentModule = Cached
```

Default cache settings are read with [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
from `LocalPreferences.toml`, next to the active project.

## Settings

| Key | Values | Default | Meaning |
|:-|:-|:-|:-|
| `maxsize` | integer ≥ 0 | `10000` | limit of each cache, in entries or bytes (see `measure`) |
| `measure` | `"count"` or `"bytes"` | `"count"` | count entries, or measure values with [`Cached.cachesize`](@ref) |
| `maxsubcaches` | integer ≥ 1 | `100` | caches kept per function, one per key and value type; the oldest is dropped first |
| `container` | `"ClockCache"` or `"LRU"` | `"ClockCache"` | container of the default `CacheStyle`; only in the `[Cached]` section |

## Where settings come from

Settings are looked up per function, in this order (first match wins):

1. runtime calls: [`set_cache_size!`](@ref) and [`set_max_subcaches!`](@ref);
2. the function's own section, `[<Package>.Cached.<function>]`;
3. the section of the package that owns the function, `[<Package>.Cached]`;
4. Cached's own section, `[Cached]`;
5. the built-in defaults above.

The package that owns a function is the package of the module that defines it, `parentmodule(typeof(f))`.
For a function extended by several packages (for example `TensorKitSectors.Fsymbol`), that is the package that defines the function, not the ones that add cached methods to it.

```toml
# LocalPreferences.toml
[Cached]
maxsize = 10000
container = "LRU"

[TensorKit.Cached]
maxsize = 50000

[TensorKit.Cached.fsbraid]
measure = "bytes"
maxsize = 2_000_000_000
maxsubcaches = 20
```

Unknown keys and invalid values are ignored with a warning.

## When changes take effect

- `maxsize`, `measure` and `maxsubcaches` are read when a function's first cache is created, so a change applies to functions that have not been called yet in the current session, and to every function after a restart.
- `container` is a compile-time preference, because it selects the default `CacheStyle`. Changing it recompiles Cached on the next start.

Use [`set_cache_preferences!`](@ref) to write the sections, which merges with what is already there:

```julia
using Cached
set_cache_preferences!(; maxsize = 50_000)                 # [Cached]
set_cache_preferences!(TensorKit; measure = "bytes")       # [TensorKit.Cached]
set_cache_preferences!(TensorKit.fsbraid; maxsize = 1000)  # [TensorKit.Cached.fsbraid]
set_cache_preferences!(TensorKit.fsbraid; maxsize = nothing) # remove a setting
```

## Measuring sizes

With `measure = "bytes"`, every cached value is measured once, on insertion, by
[`Cached.cachesize`](@ref), which defaults to `Base.summarysize`. That traverses the whole
value, which can be slow for large nested values, and counts memory shared between values
once per value. Overload it for your own types:

```julia
Cached.cachesize(t::MyTensor) = sizeof(t.data)
```
