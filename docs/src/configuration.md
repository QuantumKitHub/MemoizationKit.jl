# Configuration

```@meta
CurrentModule = Cached
```

Default cache settings are read with [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) from `LocalPreferences.toml`, next to the active project.

## Settings

| Key | Values | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `maxsize` | integer ≥ 0 | `10000` | limit of a function's cache, all signatures together, in entries or bytes (see `measure`) |
| `measure` | `"count"` or `"bytes"` | `"count"` | count entries, or measure values with [`Cached.cachesize`](@ref) |
| `container` | `"ClockCache"` or `"LRU"` | `"ClockCache"` | container of the default `CacheStyle`; only in the `[Cached]` section |
| `disk` | `true` or `false` | `true` | whether the [disk cache](disk.md) of a function with a `DiskCacheStyle` is used |
| `disk_path` | a directory | `""` (a scratch space) | where the [disk caches](disk.md) are stored |

## Where settings come from

Settings are looked up per function, in this order (first match wins):

1. runtime calls: [`set_cache_size!`](@ref);
2. the function's own section, `[<Package>.Cached.<function>]`;
3. the section of the package that owns the function, `[<Package>.Cached]`;
4. Cached's own section, `[Cached]`;
5. the built-in defaults above.

The package that owns a function is the package of the module that defines it, `parentmodule(typeof(f))`.
For a function extended by several packages, that is the package that defines the function, not the ones that add cached methods to it.

```toml
# LocalPreferences.toml
[Cached]
maxsize = 10000
container = "LRU"

[MyPackage.Cached]
maxsize = 50000

[MyPackage.Cached.expensive]
measure = "bytes"
maxsize = 2_000_000_000
```

Unknown keys and invalid values are ignored with a warning.

## When changes take effect

- `disk` and `disk_path` are read when a function first uses its disk cache in the session.
- `maxsize` and `measure` are read when a function's first cache is created, so a change applies to functions that have not been called yet in the current session, and to every function after a restart.
- `container` is a compile-time preference, because it selects the default `CacheStyle`.
  Changing it recompiles Cached on the next start.
  `GlobalCache()` and `TaskLocalCache()` use this container, so `CacheStyle` methods that return them follow the preference.

Use [`set_cache_preferences!`](@ref) to write the sections, which merges with what is already there:

```julia
using Cached
set_cache_preferences!(; maxsize = 50_000)                          # [Cached]
set_cache_preferences!(MyPackage; measure = "bytes")                # [MyPackage.Cached]
set_cache_preferences!(MyPackage.expensive; maxsize = 1000)          # [MyPackage.Cached.expensive]
set_cache_preferences!(MyPackage.expensive; maxsize = nothing)       # remove a setting
```

## Measuring sizes

With `measure = "bytes"`, every cached value is measured once, on insertion, by [`Cached.cachesize`](@ref), which defaults to `Base.summarysize`.
That traverses the whole value, which can be slow for large nested values, and counts memory shared between values once per value.
Keys and container overhead are excluded; this is a value budget, not a limit on total process memory.
Overload it for your own types:

```julia
Cached.cachesize(t::MyTensor) = sizeof(t.data)
```
