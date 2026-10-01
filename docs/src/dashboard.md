# Dashboard

```@meta
CurrentModule = Cached
```

[`cache_dashboard`](@ref) opens a terminal dashboard of the global caches, to browse them, watch
their hit rates live, and empty or resize them while your program runs. It is a package
extension on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl), so load Tachikoma first:

```julia
using Cached, Tachikoma
cache_dashboard()                                # refreshes every second
cache_dashboard(; interval = 0.2, filter = "fs") # faster, only functions whose name contains "fs"
```

The table has one row per global cache: its function, container (`LRU` or `Clock`), size and
limit (in bytes for caches measured in bytes), hits, misses, hit rate, and key and value types.
The panel below it shows the selected cache's hits per second over recent refreshes.
Task-local caches are not shown.

| Key | Action |
|:-|:-|
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a cache |
| `←` `→` | scroll the columns, when they do not fit |
| `s` / `r` | sort by the next column / reverse the order |
| `/` | filter by function name |
| `e` | empty the selected cache |
| `E` | empty all caches of the selected function, as [`empty_caches!`](@ref)`(f)` |
| `m` | set the `maxsize` of the selected cache, as [`resize!`](@ref resize!(::Cached.AbstractCache)) |
| `g` | refresh now |
| `q`, `Esc` | quit |

In the input line, `Enter` applies and `Esc` cancels. Resizing changes only the selected cache;
use [`set_cache_size!`](@ref) to change the limit of a function's current and future caches.

The statistics are read with [`cache_info`](@ref) and [`Cached.cache_stats`](@ref), which take each
cache's lock only briefly, so the dashboard is safe to run while other tasks use the caches.
