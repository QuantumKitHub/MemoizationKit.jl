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

Each function is a row, with its caches (one per key and value type) underneath, shown as call
signatures such as `fsymbol(::Int64, ::Int64, ::Int64)::Int64`. A function with a single cache
is shown as one row. The columns are a bar for the recent hit rate (over the last 10 refreshes,
`-` without lookups), a bar for the size against the limit (in bytes for caches measured in
bytes), the container (`LRU`, `Clock`, or `mixed` for a function whose caches differ), and a
sparkline of hits per second. The name column is as wide as the longest name; narrow terminals
cut names in the middle and drop columns from the right, and below 40×8 the dashboard asks for
a larger terminal. The panel at the bottom shows the numbers for the selected row, including
its lifetime hit rate. Task-local caches are not shown.

| Key | Action |
|:-|:-|
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a row |
| `←` `→`, `Space` | collapse, expand or toggle a function |
| `Enter` | resize the selected row (see below) |
| `e` | empty the selected cache, or all caches of the selected function |
| `s` / `r` | sort by the next column / reverse the order |
| `/` | filter by function name (`Enter` applies, `Esc` cancels) |
| `g` | refresh now |
| `q`, `Esc` | quit |

In resize mode, `←` and `→` halve and double the limit, `[` and `]` change it by 10%, `Enter`
applies and `Esc` cancels; the size bar previews the new limit. On a cache this calls
[`resize!`](@ref resize!(::Cached.AbstractCache)) on that cache only. On a function it sets the
limit of each of its caches, current and future, as [`set_cache_size!`](@ref), keeping the
function's measure (entries or bytes).

The statistics are read with [`cache_info`](@ref) and [`Cached.cache_stats`](@ref), which take each
cache's lock only briefly, so the dashboard is safe to run while other tasks use the caches.
