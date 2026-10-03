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
using Cached, Tachikoma, SQLite # hide
env = mktempdir() # the disk caches go to a temporary directory # hide
write(joinpath(env, "Project.toml"), "[deps]\nCached = \"$(Base.PkgId(Cached).uuid)\"\n") # hide
write(joinpath(env, "LocalPreferences.toml"), "[Cached]\ndisk_path = $(repr(mktempdir()))\n") # hide
push!(LOAD_PATH, env) # hide
Core.eval(Main, :(using Cached)) # hide
Core.eval(Main, quote # hide
    @cached fib(n::Int)::BigInt = n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2) # hide
    @cached fsymbol(a, b, c) = a + b * c # hide
    @cached matrix(n::Int)::Matrix{Float64} = zeros(n, n) # hide
    @cached label(s::Symbol; upper::Bool = false)::String = upper ? uppercase(string(s)) : string(s) # hide
    @cached wigner(j::Int)::Matrix{Float64} = ones(j, j) # hide
    Cached.CacheStyle(::typeof(fib), ::Int) = GlobalLRUCache() # hide
    Cached.DiskCacheStyle(::typeof(fib), ::Int) = DiskCache() # hide
    Cached.CacheStyle(::typeof(wigner), ::Int) = NoCache() # hide
    Cached.DiskCacheStyle(::typeof(wigner), ::Int) = DiskCache() # hide
    set_cache_size!(matrix, 2^20; by = Cached.cachesize) # hide
end) # hide
const Ext = Base.get_extension(Cached, :CachedTachikomaExt) # hide
m = Ext.Dashboard(; interval = Inf) # hide
for step in 1:40 # hide
    for i in 1:(20 + (37step) % 60) # hide
        Main.fsymbol(1 + i % 6, 1 + (7i + step) % 6, 1 + (13i) % 6) # hide
    end # hide
    step > 34 && foreach(i -> Main.fsymbol(1000step + i, 1, 1), 1:40) # a burst of new keys # hide
    step % 10 == 0 && empty_caches!(Main.fib) # then read back from disk # hide
    Main.fib(step + 20) # hide
    foreach(i -> Main.matrix(1 + (11i + 3step) % 40), 1:(1 + step % 9)) # hide
    foreach(i -> Main.label((:a, :b, :c)[1 + i % 3]; upper = isodd(step)), 1:(step % 7)) # hide
    foreach(i -> Main.wigner(1 + (5i + step) % 24), 1:(2 + step % 5)) # hide
    Ext.refresh!(m, Float64(step)) # hide
end # hide
filter!(r -> !occursin("doctest", r.label), m.rows) # functions of the doctests of other pages # hide
Ext.rebuild!(m) # hide
tb = Tachikoma.TestBackend(100, 16) # hide
frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 100, 16), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]) # hide
Tachikoma.view(m, frame) # hide
wait(m.disktask) # the entries on disk of the selected row # hide
Tachikoma.view(m, frame) # hide
foreach(y -> println(rstrip(Tachikoma.row_text(tb, y))), 1:16) # hide
Base.get_extension(Cached, :CachedSQLiteExt).close_all() # hide
filter!(!=(env), LOAD_PATH) # hide
nothing # hide
```

Each function is a row (or one per container type, in the rare case that its
[`CacheStyle`](@ref) selects several). The columns are a bar for the recent hit rate (over the
last 10 refreshes, `-` without lookups), a bar for the size against the limit (in bytes for
caches measured in bytes), the container (`LRU` or `Clock`, with `+disk` if the function also
has a [disk cache](disk.md)), and a sparkline of hits per second. The name column is as wide as the longest name; narrow terminals cut names in the middle
and drop columns from the right, and below 40×8 the dashboard asks for a larger terminal. The
panel at the bottom shows the numbers for the selected row, including its lifetime hit rate.
Task-local caches are not shown.

Functions with a disk cache appear once it is used in this process (with SQLite loaded).
Those without a RAM cache ([`NoCache`](@ref) in RAM, so every call looks on disk) have a row of
kind `Disk`, whose hit rate and activity count the lookups on disk; the disk has no size limit.
The panel of a function with a disk cache adds a line with its lookups on disk in this process
(hits are results read from disk, misses results computed and written, see
[`Cached.disk_cache_stats`](@ref)), and the entries, size and file of its database on this node
(from [`disk_cache_info`](@ref)). These are read in the background, at most every 10 seconds
(and on `g`), as counting the entries of a large database on a network file system can take a
while; `…` shows until they arrive. The header says when disk caches are off
([`disable_disk_caches!`](@ref)).

| Key | Action |
|:-|:-|
| `↑` `↓`, `PgUp` `PgDn`, `Home` `End` | select a row |
| `Enter` | resize the selected cache (see below) |
| `e` | empty the selected cache, in RAM only |
| `s` / `r` | sort by the next column / reverse the order |
| `/` | filter by function name (`Enter` applies, `Esc` cancels) |
| `g` | refresh now |
| `q`, `Esc` | quit |

In resize mode, `←` and `→` halve and double the limit, `[` and `]` change it by 10%, `Enter`
applies and `Esc` cancels; the size bar previews the new limit. Applying calls
[`set_cache_size!`](@ref) with the function's current measure (entries or bytes), so the limit
persists for the function. Both act on the cache in RAM: a disk cache is kept, and is
emptied with [`empty_disk_caches!`](@ref) outside the dashboard, as it is persistent and may be
shared with other processes.

The statistics are read with [`cache_info`](@ref) and [`Cached.cache_stats`](@ref), which take each
cache's lock only briefly, so the dashboard is safe to run while other tasks use the caches.
