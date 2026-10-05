# Dashboard

```@meta
CurrentModule = Cached
```

[`cache_dashboard`](@ref) opens a terminal dashboard of the global caches, to browse them, watch their hit rates live, and empty or resize them while your program runs.
It is a package extension on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl), so load Tachikoma first:

```julia
using Cached, Tachikoma
cache_dashboard()                                # refreshes every second
cache_dashboard(; interval = 0.2, filter = "fs") # faster, only functions whose name contains "fs"
```

It has two tabs, for the caches in RAM and on disk.

Narrow terminals shorten names and drop columns.
The minimum size is 40×8.

| Key | Action |
| :--- | :--- |
| `Tab`, `1` / `2` | switch to the next tab / the RAM or Disk tab |
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a row |
| `Enter` | resize the selected cache, in RAM |
| `e` | empty the selected cache, in RAM |
| `s` / `r` | sort by the next column / reverse the order, per tab |
| `/` | filter by function name, on both tabs (`Enter` applies, `Esc` cancels) |
| `g` | refresh now |
| `q`, `Esc` | quit |

Statistics are copied under brief locks, so the dashboard can run while other tasks use the caches.

## RAM caches

With a few example caches, the RAM tab looks like this (rendered while building these docs):

```@example dashboard
using Cached, Tachikoma, SQLite # hide
env = mktempdir() # the disk caches go to a temporary directory # hide
write(joinpath(env, "Project.toml"), "[deps]\nCached = \"$(Base.PkgId(Cached).uuid)\"\n") # hide
write(joinpath(env, "LocalPreferences.toml"), "[Cached]\ndisk_path = $(repr(mktempdir()))\n") # hide
push!(LOAD_PATH, env) # hide
Core.eval(Main, :(using Cached)) # hide
Core.eval(Main, quote # hide
    @cached fib(n::Int)::BigInt = n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2) # hide
    @cached weights(a, b, c) = a + b * c # hide
    @cached matrix(n::Int)::Matrix{Float64} = zeros(n, n) # hide
    @cached label(s::Symbol; upper::Bool = false)::String = upper ? uppercase(string(s)) : string(s) # hide
    @cached kernel(j::Int)::Matrix{Float64} = ones(j, j) # hide
    Cached.CacheStyle(::typeof(fib), ::Int) = GlobalLRUCache() # hide
    Cached.DiskCacheStyle(::typeof(fib), ::Int) = DiskCache() # hide
    Cached.CacheStyle(::typeof(kernel), ::Int) = NoCache() # hide
    Cached.DiskCacheStyle(::typeof(kernel), ::Int) = DiskCache() # hide
    set_cache_size!(matrix, 2^20; by = Cached.cachesize) # hide
end) # hide
const Ext = Base.get_extension(Cached, :CachedTachikomaExt) # hide
m = Ext.Dashboard(; interval = Inf) # hide
for step in 1:40 # hide
    for i in 1:(20 + (37step) % 60) # hide
        Main.weights(1 + i % 6, 1 + (7i + step) % 6, 1 + (13i) % 6) # hide
    end # hide
    step > 34 && foreach(i -> Main.weights(1000step + i, 1, 1), 1:40) # a burst of new keys # hide
    step % 10 == 0 && empty_caches!(Main.fib) # then read back from disk # hide
    Main.fib(step + 20) # hide
    foreach(i -> Main.matrix(1 + (11i + 3step) % 40), 1:(1 + step % 9)) # hide
    foreach(i -> Main.label((:a, :b, :c)[1 + i % 3]; upper = isodd(step)), 1:(step % 7)) # hide
    foreach(i -> Main.kernel(1 + (5i + step) % 24), 1:(2 + step % 5)) # hide
    Ext.refresh!(m, Float64(step)) # hide
end # hide
foreach(t -> filter!(r -> r.f in (Main.fib, Main.weights, Main.matrix, Main.label, Main.kernel), t.rows), m.tabs) # only this page's examples # hide
Ext.rebuild!(m) # hide
function preview(m, height) # hide
    tb = Tachikoma.TestBackend(100, height) # hide
    Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 100, height), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])) # hide
    return foreach(y -> println(rstrip(Tachikoma.row_text(tb, y))), 1:height) # hide
end # hide
preview(m, 16) # hide
```

The RAM tab shows one row per function and container type: recent hit rate, size against its limit, cache kind, and hits per second.
The header totals entries and byte-measured values; the selected row's details include lifetime statistics.
Recent hit rates cover the last 10 refreshes.
Task-local caches are not shown.

In resize mode, `←` / `→` halve or double the limit, `[` / `]` adjust it by 10%, `Enter` applies, and `Esc` cancels.
The preview uses the cache's current measure (entries or bytes); applying calls [`set_cache_size!`](@ref).

Emptying and resizing act on RAM only.

## Disk caches

The Disk tab lists the disk caches opened in this process, including functions without a RAM cache:

```@example dashboard
m.tab = 2 # hide
wait(Ext.read_disk!(m).disktask) # the entries and sizes on disk # hide
preview(m, 8) # hide
Base.get_extension(Cached, :CachedSQLiteExt).close_all() # hide
filter!(!=(env), LOAD_PATH) # hide
nothing # hide
```

The Disk tab shows database entries and size (including the write-ahead log), hit rate, and activity.
The selected row adds the database path.
Hit/miss counters cover this process; entries and sizes describe the database shared on this machine.

Database sizes and entry counts are read in the background, at most every 10 seconds while the tab is shown, or on `g`.
`…` appears until they arrive.
The header indicates when [`disable_disk_caches!`](@ref) has turned disk caching off.

Use [`empty_disk_caches!`](@ref) to clear persistent results outside the dashboard.
