# Configuration

```@meta
CurrentModule = MemoizationKit
```

Default cache settings are read with [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) from `LocalPreferences.toml`, next to the active project.

## Settings

| Key | Values | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `maxsize` | integer ≥ 0 | `10000` | limit of a function's cache, all signatures together, in entries or bytes (see `measure`) |
| `measure` | `"count"` or `"bytes"` | `"count"` | count entries, or measure values with [`MemoizationKit.cachesize`](@ref) |
| `container` | `"ClockCache"` or `"LRU"` | `"ClockCache"` | container of the default `CacheStyle`; only in the `[MemoizationKit]` section |
| `disk` | `true` or `false` | `true` | whether the [disk cache](disk.md) of a function with a `DiskCacheStyle` is used |
| `disk_path` | a directory | `""` (a scratch space) | where the [disk caches](disk.md) are stored |

## Where settings come from

Settings are looked up per function, in this order (first match wins):

1. runtime calls: [`set_cache_size!`](@ref);
2. the function's own section, `[<Package>.MemoizationKit.<function>]`;
3. the section of the package that owns the function, `[<Package>.MemoizationKit]`;
4. MemoizationKit's own section, `[MemoizationKit]`;
5. the built-in defaults above.

The package that owns a function is the package of the module that defines it, `parentmodule(typeof(f))`.
For a function extended by several packages, that is the package that defines the function, not the ones that add cached methods to it.

```toml
# LocalPreferences.toml
[MemoizationKit]
maxsize = 10000
container = "LRU"

[MyPackage.MemoizationKit]
maxsize = 50000

[MyPackage.MemoizationKit.expensive]
measure = "bytes"
maxsize = 2_000_000_000
```

Unknown keys and invalid values are ignored with a warning.

## When changes take effect

- `disk` and `disk_path` are read when a function first uses its disk cache in the session.
- `maxsize` and `measure` are read when a function's first cache is created, so a change applies to functions that have not been called yet in the current session, and to every function after a restart.
- `container` is a compile-time preference, because it selects the default `CacheStyle`.
  Changing it recompiles MemoizationKit on the next start.
  `GlobalCache()` and `TaskLocalCache()` use this container, so `CacheStyle` methods that return them follow the preference.

Use [`set_cache_preferences!`](@ref) to write the sections, which merges with what is already there:

```@example preferences
using MemoizationKit
sample = include(joinpath(pkgdir(MemoizationKit), "docs", "examples", "package.jl")) # hide
MyPackage = sample.package # hide
with_preferences = sample.with_preferences # hide
with_preferences() do # hide
set_cache_preferences!(; maxsize = 50_000) # [MemoizationKit]
println(read("LocalPreferences.toml", String))
end # hide
```

For functions defined in your package, use package or function settings:

```@example preferences
with_preferences() do # hide
set_cache_preferences!(MyPackage; measure = "bytes")       # [MyPackage.MemoizationKit]
set_cache_preferences!(MyPackage.expensive; maxsize = 1000) # [MyPackage.MemoizationKit.expensive]
println(read("LocalPreferences.toml", String))
end # hide
```

Remove a setting by passing `nothing`:

```@example preferences
with_preferences() do # hide
set_cache_preferences!(MyPackage.expensive; maxsize = nothing)
println(read("LocalPreferences.toml", String))
end # hide
```

## Measuring sizes

With `measure = "bytes"`, every cached value is measured once, on insertion, by [`MemoizationKit.cachesize`](@ref), which defaults to `Base.summarysize`.
That traverses the whole value, which can be slow for large nested values, and counts memory shared between values once per value.
Keys and container overhead are excluded; this is a value budget, not a limit on total process memory.
Overload it for your own types:

```jldoctest
using MemoizationKit

struct MyTensor
    data::Vector{Float64}
end
MemoizationKit.cachesize(t::MyTensor) = sizeof(t.data);

MemoizationKit.cachesize(MyTensor(zeros(10)))

# output

80
```
