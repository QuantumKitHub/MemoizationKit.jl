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

With a few example caches it looks like this (rendered while building these docs):

```@example dashboard
using Cached, Tachikoma # hide
Core.eval(Main, :(using Cached)) # hide
Core.eval(Main, quote # hide
    @cached fib(n::Int)::BigInt = n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2) # hide
    @cached fsymbol(a, b, c) = a + b * c # hide
    @cached matrix(n::Int)::Matrix{Float64} = zeros(n, n) # hide
    @cached label(s::Symbol; upper::Bool = false)::String = upper ? uppercase(string(s)) : string(s) # hide
    Cached.CacheStyle(::typeof(fib), ::Int) = GlobalLRUCache() # hide
    set_cache_size!(matrix, 2^20; by = Cached.cachesize) # hide
end) # hide
const Ext = Base.get_extension(Cached, :CachedTachikomaExt) # hide
m = Ext.Dashboard(; interval = Inf) # hide
for step in 1:40 # hide
    for i in 1:(20 + (37step) % 60) # hide
        Main.fsymbol(1 + i % 6, 1 + (7i + step) % 6, 1 + (13i) % 6) # hide
    end # hide
    step > 34 && foreach(i -> Main.fsymbol(1000step + i, 1, 1), 1:40) # a burst of new keys # hide
    Main.fib(step + 20) # hide
    foreach(i -> Main.matrix(1 + (11i + 3step) % 40), 1:(1 + step % 9)) # hide
    foreach(i -> Main.label((:a, :b, :c)[1 + i % 3]; upper = isodd(step)), 1:(step % 7)) # hide
    Ext.refresh!(m, Float64(step)) # hide
end # hide
Tachikoma.update!(m, Tachikoma.KeyEvent(:down)) # hide
tb = Tachikoma.TestBackend(100, 16) # hide
frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 100, 16), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]) # hide
Tachikoma.view(m, frame) # hide
foreach(y -> println(rstrip(Tachikoma.row_text(tb, y))), 1:16) # hide
```

Each function is a row (or one per container type, in the rare case that its
[`CacheStyle`](@ref) selects several). The columns are a bar for the recent hit rate (over the
last 10 refreshes, `-` without lookups), a bar for the size against the limit (in bytes for
caches measured in bytes), the container (`LRU` or `Clock`), and a sparkline of hits per
second. The name column is as wide as the longest name; narrow terminals cut names in the middle
and drop columns from the right, and below 40×8 the dashboard asks for a larger terminal. The
panel at the bottom shows the numbers for the selected row, including its lifetime hit rate.
Task-local caches are not shown.

| Key | Action |
|:-|:-|
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a row |
| `Enter` | resize the selected cache (see below) |
| `e` | empty the selected cache |
| `s` / `r` | sort by the next column / reverse the order |
| `/` | filter by function name (`Enter` applies, `Esc` cancels) |
| `g` | refresh now |
| `q`, `Esc` | quit |

In resize mode, `←` and `→` halve and double the limit, `[` and `]` change it by 10%, `Enter`
applies and `Esc` cancels; the size bar previews the new limit. Applying calls
[`set_cache_size!`](@ref) with the function's current measure (entries or bytes), so the limit
persists for the function.

The statistics are read with [`cache_info`](@ref) and [`Cached.cache_stats`](@ref), which take each
cache's lock only briefly, so the dashboard is safe to run while other tasks use the caches.
