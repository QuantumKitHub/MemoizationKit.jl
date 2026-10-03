using Test
using Cached

@testset "error hint without Tachikoma" begin
    # a fresh process with Cached only, since this one loads Tachikoma
    mktempdir() do env
        code = """
        using Pkg
        Pkg.activate($(repr(env)); io = devnull)
        Pkg.develop(path = $(repr(pkgdir(Cached))); io = devnull)
        using Cached
        for call in (() -> cache_dashboard(), () -> cache_dashboard(; interval = 2))
            try
                call()
            catch e
                println(e isa MethodError, " ", sprint(showerror, e))
            end
        end
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no -e $code`,
            "JULIA_PKG_OFFLINE" => "true", "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ";" : ":"), "JULIA_PROJECT" => nothing,
        )
        out = read(cmd, String)
        @test count("true MethodError: no method matching cache_dashboard(", out) == 2
        @test count("`cache_dashboard` needs Tachikoma.jl: run `using Tachikoma` first", out) == 2
    end
end

using Tachikoma: Tachikoma, TestBackend, KeyEvent, Rect, Frame, GraphicsRegion, PixelSnapshot, find_text, row_text

const Ext = Base.get_extension(Cached, :CachedTachikomaExt)

@testset "no hint with Tachikoma loaded" begin
    @test hasmethod(Cached.cache_dashboard, Tuple{})
    e = try
        cache_dashboard(1)
    catch e
        e
    end
    @test e isa MethodError && !occursin("needs Tachikoma", sprint(showerror, e))
end

# unique names, as other test files may share this process and its global caches
@cached dash_square(x) = x^2
@cached dash_bytes(n::Int)::Vector{Float64} = zeros(n)
@cached dash_late(x) = x
@cached dash_lru(x) = x
Cached.CacheStyle(::typeof(dash_lru), x) = GlobalLRUCache()
@cached dash_two(x) = x # one cache per container type
Cached.CacheStyle(::typeof(dash_two), ::Int) = GlobalLRUCache()

function draw(m; width = 120, height = 24)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end
press(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)
line(tb, text) = (p = find_text(tb, text); p === nothing ? "" : row_text(tb, p.y))
# screen column of `text` (`find_text` gives a string index)
column(tb, text) = (p = find_text(tb, text); textwidth(row_text(tb, p.y)[1:(p.x - 1)]) + 1)
select!(m, f) = (m.selected = findfirst(r -> r.f === f, m.lines); m)
function dashboard(filter)
    m = Ext.Dashboard(; interval = Inf, filter)
    Ext.refresh!(m)
    return m
end

foreach(dash_square, (1, 2, 3, 1, 2, 1.0))
set_cache_size!(dash_bytes, 10^6; by = Cached.cachesize)
dash_bytes(10);
dash_bytes(10);
dash_lru(1)
dash_two(1)
dash_two(1.0)

@testset "formatting" begin
    @test Ext._truncate("abcdefghij", 7) == "abcd…ij"
    @test Ext._truncate("abc", 7) == "abc"
    # by display width: wide characters take two columns
    @test Ext._truncate("漢字漢字漢字", 7) == "漢字…字" && textwidth(Ext._truncate("漢字漢字漢字", 8)) <= 8
    @test Ext._truncate("abc", 1) == "…" && Ext._truncate("abc", 0) == ""
    @test Ext._short(216, false) == "216" && Ext._short(10_000, false) == "10k" && Ext._short(1234, false) == "1.2k"
    @test Ext._short(1023, true) == "1023B" && Ext._short(1024^2, true) == "1.0MiB" && Ext._short(64 * 1024^3, true) == "64GiB"
end

@testset "one row per cache" begin
    m = dashboard("dash_")
    square = only(r for r in m.lines if r.f === dash_square)
    @test (square.stats.hits, square.stats.misses, square.stats.length) == (2, 4, 4)
    @test square.label == repr(dash_square)

    tb = draw(m; width = 160) # names are qualified by the test module
    @test occursin("Clock", line(tb, repr(dash_square)))
    @test occursin("LRU", line(tb, repr(dash_lru)))
    # a function with caches of two container types has a row for each
    two = filter(r -> r.f === dash_two, m.lines)
    @test length(two) == 2 && Set(r.kind for r in two) == Set(["LRU", "Clock"])
    @test occursin(r"\d+B/977KiB", line(tb, repr(dash_bytes)))
    @test find_text(tb, "Activity") !== nothing && find_text(tb, "q quit") !== nothing
    # no recent lookups yet; the lifetime rate is in the detail panel
    @test occursin("░░░░░░-░░░░░░", line(tb, repr(dash_square)))
    select!(m, dash_square)
    @test find_text(draw(m; width = 160), "lifetime 33.3%") !== nothing # 2 hits, 4 misses

    # the name column is as wide as the longest name, with spare width at the right
    longest = maximum(r -> textwidth(r.label), m.lines)
    @test column(tb, "Name") == 2
    @test column(tb, "Hit rate") == 1 + 1 + max(longest, 20) + 1
    @test column(tb, "Size") == column(tb, "Hit rate") + 14
    tb = draw(m; width = 50)
    @test column(tb, "Hit rate") == 1 + 1 + clamp(longest, 20, 50 - 1 - 14) + 1
    longest > 35 && @test find_text(tb, "…") !== nothing

    # sorting by recent hit rate, descending: dash_bytes (100%) before dash_square (50%)
    dash_bytes(10)
    dash_square(1)
    dash_square(7)
    Ext.refresh!(m, m.lastrefresh + 1)
    @test occursin("50%", line(draw(m; width = 160), repr(dash_square)))
    press(m, 's', 'r')
    @test first(Ext.SORTS[m.sortcol]) == "Hit rate"
    @test findfirst(r -> r.f === dash_bytes, m.lines) < findfirst(r -> r.f === dash_square, m.lines)
    press(m, 's', 's', 's', 'r')
    @test m.sortcol == 1 && !m.reverse

    # filter through the input line
    press(m, '/', ntuple(_ -> :backspace, 10)..., 'l', 'r', 'u', :enter)
    @test m.filter == "lru" && length(m.lines) == 1
    press(m, 'q')
    @test Tachikoma.should_quit(m)
end

@testset "empty state and small terminals" begin
    m = Ext.Dashboard(; interval = Inf, lastrefresh = time())
    @test find_text(draw(m), "No global caches yet") !== nothing
    press(m, :down, :enter, 'e', :end_key) # no selection: nothing happens
    @test m.pending === nothing && !m.quit

    @test find_text(draw(dashboard("no such function")), "No caches match") !== nothing

    m = dashboard("dash_")
    @test draw(m; width = 1, height = 1) isa TestBackend
    @test draw(m; width = 10, height = 2) isa TestBackend
    @test find_text(draw(m; width = 39, height = 30), "terminal too small (need 40×8)") !== nothing
    @test find_text(draw(m; width = 100, height = 7), "terminal too small") !== nothing

    # columns are dropped as the terminal narrows, and the detail panel below 16 rows
    tb = draw(m; width = 40, height = 8)
    @test find_text(tb, "too small") === nothing && find_text(tb, "Hit rate") !== nothing
    @test find_text(tb, "Size") === nothing
    @test find_text(draw(m; width = 60, height = 15), "Size") !== nothing
    @test find_text(draw(m; width = 60, height = 15), "Kind") === nothing
    @test find_text(draw(m; width = 69, height = 15), "Kind") !== nothing
    @test find_text(draw(m; width = 69, height = 15), "Activity") === nothing
    @test find_text(draw(m; width = 78, height = 15), "Activity") !== nothing
    @test find_text(draw(m; width = 80, height = 15), "hits/s") === nothing
    @test find_text(draw(m; width = 80, height = 16), "hits/s") !== nothing
end

const many = [@eval(@cached $(Symbol(:dash_many, i))(x) = x) for i in 1:7]
foreach(f -> f(1), many)

@testset "scrolling back when the terminal grows" begin
    m = dashboard("dash_many")
    @test length(m.lines) == 7
    m.selected = length(m.lines)
    draw(m; width = 60, height = 8) # scrolls down to show the selection
    @test m.offset > 0
    draw(m; width = 60, height = 30) # everything fits again
    @test m.offset == 0
end

@testset "empty and resize through key events" begin
    m = dashboard("dash_square")
    c = only(m.lines).cache
    press(m, 'e')
    @test isempty(c)
    @test occursin("dash_square", line(draw(m), "emptied"))

    old = Cached.cache_stats(c).maxsize
    press(m, :enter)
    @test m.pending == old
    press(m, :right, :right, :left)
    @test m.pending == 2old
    @test find_text(draw(m), "$(Ext._short(old, false)) → $(Ext._short(2old, false))") !== nothing
    press(m, ']')
    @test m.pending == 2old + round(Int, 2old / 10)
    press(m, :escape)
    @test m.pending === nothing && Cached.cache_stats(c).maxsize == old && !m.quit
    press(m, :enter, :left, '[', :enter)
    n = old ÷ 2 - round(Int, (old ÷ 2) / 10)
    @test Cached.cache_stats(c).maxsize == n
    @test occursin("dash_square", line(draw(m), "set the limit"))
    # the limit is the function's (set with `set_cache_size!`), so it persists
    @test Cached.REGISTRY.functions[dash_square].maxsize == n
end

@testset "resizing a byte-measured function keeps its cache" begin
    m = dashboard("dash_bytes")
    c = only(m.lines).cache
    @test Cached.cache_stats(c).by !== nothing && length(c) == 1
    press(m, :enter, :right, :enter)
    @test only(cache_info(dash_bytes)).second === c # not discarded
    @test length(c) == 1 && Cached.cache_stats(c).by !== nothing && Cached.cache_stats(c).maxsize == 2 * 10^6
end

@testset "refresh picks up new caches and rates" begin
    m = Ext.Dashboard(; interval = 0.0, filter = "dash_late")
    draw(m)
    @test isempty(m.lines)
    dash_late(1)
    tb = draw(m)
    @test length(m.lines) == 1 && find_text(tb, repr(dash_late)) !== nothing
    Ext.refresh!(m, m.lastrefresh + 1)
    foreach(_ -> dash_late(1), 1:4)
    Ext.refresh!(m, m.lastrefresh + 2)
    late = only(m.lines)
    @test late.trend.rates[end] ≈ 2.0 && Ext.recent(late.trend) == 1.0

    # caches that disappear are dropped, with their trends
    set_cache_size!(dash_late, 10; by = Cached.cachesize) # discards the cache
    Ext.refresh!(m)
    @test isempty(m.lines) && !haskey(m.trends, late.cache)
    @test draw(m) isa TestBackend
end

@cached dash_rate(x) = x

@testset "recent hit rate" begin
    m = Ext.Dashboard(; interval = Inf, filter = "dash_rate")
    dash_rate(1)
    t = 0.0
    misses = Ref(10)
    function step!(hits, nmisses)
        foreach(_ -> dash_rate(1), 1:hits)
        foreach(_ -> dash_rate(misses[] += 1), 1:nmisses)
        Ext.refresh!(m, t += 1)
        return only(m.lines)
    end
    rate(r) = Ext.recent(r.trend)
    Ext.refresh!(m, t)
    for _ in 1:20
        step!(100, 0)
    end
    r = step!(0, 0)
    @test rate(r) == 1.0 && occursin("100%", line(draw(m), repr(dash_rate)))

    # a burst of misses shows up straight away, and fully within a window
    r = step!(0, 400)
    @test rate(r) ≈ 800 / 1200 && Ext.hitrate(r.stats) > 0.8
    for _ in 1:Ext.WINDOW
        r = step!(0, 10)
    end
    @test rate(r) == 0.0
    @test occursin("░0%░", line(draw(m), repr(dash_rate)))
    @test occursin("lifetime", line(draw(m), "hit rate: recent 0.0%"))

    # and recovers when hits resume
    for _ in 1:Ext.WINDOW
        r = step!(50, 0)
    end
    @test rate(r) == 1.0

    # without lookups in the window: `-`
    for _ in 1:Ext.WINDOW
        r = step!(0, 0)
    end
    @test isnan(rate(r)) && occursin("░░░░░░-░░░░░░", line(draw(m), repr(dash_rate)))
end

@cached 漢字の長い関数名前漢字の長い関数名前(x) = x

@testset "wide characters in names" begin
    漢字の長い関数名前漢字の長い関数名前(1)
    m = dashboard("漢字")
    for width in (40, 160)
        tb = draw(m; width)
        namewidth = clamp(textwidth(only(m.lines).label), 20, width - 1 - (width < 58 ? 14 : 14 + 23 + 6 + 9))
        row = row_text(tb, 3) # the only row; wide characters are followed by a padding cell
        # the gauge starts right after the name column, as in the header
        @test textwidth(row[1:(findfirst('░', row) - 1)]) + 1 == column(tb, "Hit rate") == namewidth + 3
    end
end

@testset "without SQLite" begin
    # a fresh process with this environment, which has SQLite without loading it
    code = """
    using Cached, Tachikoma
    const Ext = Base.get_extension(Cached, :CachedTachikomaExt)
    @cached nosql(x) = x
    nosql(1)
    m = Ext.Dashboard(; interval = Inf, filter = "nosql")
    Ext.refresh!(m)
    tb = Tachikoma.TestBackend(100, 20)
    Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 100, 20), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]))
    print(Base.get_extension(Cached, :CachedSQLiteExt) === nothing, " ", length(m.lines), " ")
    print(Tachikoma.find_text(tb, "Clock") !== nothing, " ", Tachikoma.find_text(tb, "disk") === nothing)
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no -t1 --heap-size-hint=1G --project=$(Base.active_project()) -e $code`
    @test read(addenv(cmd, "JULIA_PKG_OFFLINE" => "true"), String) == "true 1 true true"
end

using SQLite: SQLite
include(joinpath(pkgdir(Cached), "benchmark", "disk_stress.jl")) # `use_disk_path`
const DISK_ENV = use_disk_path(mktempdir())

@cached dash_disk(x::Int) = x + 1
Cached.DiskCacheStyle(::typeof(dash_disk), ::Int) = DiskCache()
@cached dash_diskonly(x::Int)::Int = 2x
Cached.CacheStyle(::typeof(dash_diskonly), ::Int) = NoCache()
Cached.DiskCacheStyle(::typeof(dash_diskonly), ::Int) = DiskCache()
@cached dash_disknotyet(x::Int) = x # its store is opened on the first call
Cached.DiskCacheStyle(::typeof(dash_disknotyet), ::Int) = DiskCache()

# Draw until the entries on disk of the selected row are read.
function settle!(m)
    tb = draw(m)
    while m.disktask !== nothing
        wait(m.disktask)
        tb = draw(m)
    end
    return tb
end

@testset "disk caches" begin
    dash_disk(1), dash_disk(2)
    empty_caches!(dash_disk)
    dash_disk(1) # two misses on disk, then a hit
    foreach(dash_diskonly, (1, 1, 1, 2))
    stats = Dict(Cached.disk_cache_stats())
    @test stats[dash_disk] == (; hits = 1, misses = 2) && stats[dash_diskonly] == (; hits = 2, misses = 2)
    @test !haskey(stats, dash_disknotyet)

    m = dashboard("dash_disk")
    @test length(m.lines) == 2 # not `dash_disknotyet`
    ram = only(r for r in m.lines if r.f === dash_disk)
    disk = only(r for r in m.lines if r.f === dash_diskonly)
    @test ram.kind == "Clock+disk" && ram.disk == (; hits = 1, misses = 2) && ram.stats.length == 1
    @test disk.cache === nothing && disk.kind == "Disk" && (disk.stats.hits, disk.stats.misses) == (2, 2)
    tb = draw(m; width = 160)
    @test occursin("Clock+disk", line(tb, repr(dash_disk)))
    @test occursin(r"no limit \(disk\) +Disk", line(tb, repr(dash_diskonly)))
    @test occursin(r"\d+ caches, \d+ entries in RAM · filter", row_text(tb, 1))

    # the detail panel reads the entries on disk in the background
    select!(m, dash_diskonly)
    tb = draw(m)
    @test find_text(tb, "Disk only, no RAM cache") !== nothing
    @test occursin("disk: 2 hits · 2 misses (50.0%) · … entries", line(tb, "disk:"))
    tb = settle!(m)
    @test occursin(r"disk: 2 hits · 2 misses \(50.0%\) · 2 entries · \d+(\.\d)?KiB · /", line(tb, "disk:"))
    draw(m)
    @test m.disktask === nothing # read at most every DISKINTERVAL seconds
    press(m, 'g')
    draw(m)
    @test m.disktask !== nothing
    settle!(m)

    # hit rate and activity of a disk-only row are those of the disk
    foreach(dash_diskonly, (1, 2, 1, 3))
    Ext.refresh!(m, m.lastrefresh + 1)
    disk = only(r for r in m.lines if r.f === dash_diskonly)
    @test Ext.recent(disk.trend) == 0.75 && disk.trend.rates[end] == 3.0

    # the disk is neither emptied nor resized
    select!(m, dash_diskonly)
    press(m, 'e')
    @test occursin(repr(dash_diskonly), line(draw(m), "is cached on disk only")) && only(disk_cache_info(dash_diskonly)).second.entries == 3
    press(m, :enter)
    @test m.pending === nothing
    select!(m, dash_disk)
    press(m, 'e')
    @test isempty(only(cache_info(dash_disk)).second) && only(disk_cache_info(dash_disk)).second.entries == 2
    @test occursin("its disk cache is kept", line(draw(m), "emptied"))
    press(m, :enter)
    @test occursin(repr(dash_disk) * " (RAM)", line(draw(m), "→"))
    press(m, :escape)

    disable_disk_caches!()
    try
        tb = draw(m)
        @test find_text(tb, "disk caches off") !== nothing && occursin("disk (off): ", line(tb, "disk (off)"))
    finally
        enable_disk_caches!()
    end

    # the smallest terminal shows the rows, without the detail panel
    tb = draw(m; width = 40, height = 8)
    @test find_text(tb, "too small") === nothing && find_text(tb, "Hit rate") !== nothing
    @test occursin("░", row_text(tb, 4)) && find_text(tb, "disk:") === nothing # both rows
    # Kind fits from 69 columns on
    @test find_text(draw(m; width = 68, height = 15), "Kind") === nothing
    @test find_text(draw(m; width = 69, height = 15), "Clock+disk") !== nothing
end

Base.get_extension(Cached, :CachedSQLiteExt).close_all()
filter!(!=(DISK_ENV), LOAD_PATH)
