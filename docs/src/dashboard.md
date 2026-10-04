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

It has two tabs, for the caches in RAM and on disk. With a few example caches, the RAM tab
looks like this (rendered while building these docs):

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
foreach(t -> filter!(r -> !occursin("doctest", r.label), t.rows), m.tabs) # functions of the doctests of other pages # hide
Ext.rebuild!(m) # hide
function preview(m, height) # hide
    tb = Tachikoma.TestBackend(100, height) # hide
    Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 100, height), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])) # hide
    return foreach(y -> println(rstrip(Tachikoma.row_text(tb, y))), 1:height) # hide
end # hide
preview(m, 16) # hide
```

The header sums all caches: their entries, the bytes of those measured in bytes, and the recent
hit rate (over the last 10 refreshes). Each function is a row (or one per container type, in
the rare case that its [`CacheStyle`](@ref) selects several). The columns are a bar for the
recent hit rate (`-` without lookups), a bar for the size against the limit (in bytes for
caches measured in bytes), the container (`LRU` or `Clock`, with `+disk` if the function also
has a [disk cache](disk.md)), and a sparkline of hits per second. The panel at the bottom shows
the numbers for the selected row, including its lifetime hit rate. Task-local caches are not
shown.

The Disk tab (`Tab`, or `2`) lists the functions whose [disk cache](disk.md) is open in this
process (with SQLite loaded), including those without a cache in RAM:

```@example dashboard
m.tab = 2 # hide
wait(Ext.read_disk!(m).disktask) # the entries and sizes on disk # hide
preview(m, 8) # hide
Base.get_extension(Cached, :CachedSQLiteExt).close_all() # hide
filter!(!=(env), LOAD_PATH) # hide
nothing # hide
```

Its columns are the entries and size of each database on this node (the size includes the
write-ahead log), the hit rate of the lookups on disk, and their activity; the panel adds the
path of the database. Hits are results read from disk and misses results computed and written,
counted in this process (see [`Cached.disk_cache_stats`](@ref)); the header sums them over all
disk caches, with the total entries and size, and says when disk caches are off
([`disable_disk_caches!`](@ref)). The entries and sizes come from [`disk_cache_info`](@ref),
which is read in the background while the tab is shown, at most every 10 seconds (and on `g`),
as counting the entries of a large database on a network file system can take a while; `…`
shows until they arrive.

The name column is as wide as the longest name; narrow terminals cut names in the middle and
drop columns from the right, and below 40×8 the dashboard asks for a larger terminal.

| Key | Action |
|:-|:-|
| `Tab`, `1` / `2` | switch to the next tab / the RAM or Disk tab |
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a row |
| `Enter` | resize the selected cache, in RAM (see below) |
| `e` | empty the selected cache, in RAM |
| `s` / `r` | sort by the next column / reverse the order, per tab |
| `/` | filter by function name, on both tabs (`Enter` applies, `Esc` cancels) |
| `g` | refresh now |
| `q`, `Esc` | quit |

In resize mode, `←` and `→` halve and double the limit, `[` and `]` change it by 10%, `Enter`
applies and `Esc` cancels; the size bar previews the new limit. Applying calls
[`set_cache_size!`](@ref) with the function's current measure (entries or bytes), so the limit
persists for the function. Emptying and resizing act on the RAM tab only: a disk cache is
persistent and may be shared with other processes, so it is emptied with
[`empty_disk_caches!`](@ref) outside the dashboard.

The statistics are read with [`cache_info`](@ref) and [`Cached.cache_stats`](@ref), which take each
cache's lock only briefly, so the dashboard is safe to run while other tasks use the caches.
