using Test
using Cached

@testset "dashboard needs Tachikoma" begin
    if Base.get_extension(Cached, :CachedTachikomaExt) === nothing
        @test_throws r"using Tachikoma" cache_dashboard()
    end
end

using Tachikoma: Tachikoma, TestBackend, KeyEvent, Rect, Frame, GraphicsRegion, PixelSnapshot, find_text

const Ext = Base.get_extension(Cached, :CachedTachikomaExt)

# unique names, as other test files may share this process and its global caches
@cached dash_square(x::Int) = x^2
@cached dash_bytes(n::Int)::Vector{Float64} = zeros(n)
@cached dash_late(x) = x

function draw(m; width = 120, height = 24)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end
press(m, keys...) = foreach(k -> Tachikoma.update!(m, k isa Char ? KeyEvent(k) : KeyEvent(k)), keys)
row(m, f) = m.visible[findfirst(r -> r.f === f, m.visible)]

foreach(dash_square, (1, 2, 3, 1, 2))
set_cache_size!(dash_bytes, 10^6; by = Cached.cachesize)
dash_bytes(10);
dash_bytes(10);

@testset "rows show functions and statistics" begin
    m = Ext.Dashboard(; interval = Inf, filter = "dash_")
    Ext.refresh!(m)
    @test length(m.visible) == 2
    r = row(m, dash_square)
    @test (r.stats.hits, r.stats.misses, r.stats.length) == (2, 3, 3)
    @test r.keytype == "Tuple{Int64}" && r.valtype == "Int64" && !r.bytes

    tb = draw(m; width = 160) # names are qualified by the test module
    y = find_text(tb, "dash_square").y
    line = Tachikoma.row_text(tb, y)
    @test occursin("Clock", line) || occursin("LRU", line)
    @test occursin("3/$(r.stats.maxsize)", line) && occursin("40.0%", line)
    @test occursin("Vector{Float64}", Tachikoma.row_text(tb, find_text(tb, "dash_bytes").y))
    @test occursin(r"\d+ B/976.6 KiB", Tachikoma.row_text(tb, find_text(tb, "dash_bytes").y))
    @test find_text(tb, "2 caches") !== nothing
    @test find_text(tb, "q quit") !== nothing

    # sorting by hits, descending: dash_square (2 hits) before dash_bytes (1 hit)
    press(m, 's', 's', 's', 'r')
    @test m.sortcol == 4 && first(m.visible).f === dash_square
    press(m, 'r')
    @test first(m.visible).f === dash_bytes
end

@testset "empty state and small terminals" begin
    m = Ext.Dashboard(; interval = Inf, lastrefresh = time())
    @test find_text(draw(m), "No global caches yet") !== nothing
    press(m, :down, 'e', 'E', 'm', :up) # no selection: nothing happens
    @test m.input === nothing && !m.quit

    m = Ext.Dashboard(; interval = Inf, filter = "no such function")
    Ext.refresh!(m)
    @test find_text(draw(m), "No caches match") !== nothing

    m = Ext.Dashboard(; interval = Inf, filter = "dash_")
    Ext.refresh!(m)
    for (w, h) in ((1, 1), (10, 2), (20, 5), (40, 11), (40, 12))
        @test draw(m; width = w, height = h) isa TestBackend
    end
end

@testset "empty and resize through key events" begin
    m = Ext.Dashboard(; interval = Inf, filter = "dash_square")
    Ext.refresh!(m)
    c = only(m.visible).cache
    @test Ext.selected(m).cache === c
    press(m, 'e')
    @test isempty(c) && only(m.visible).stats.length == 0
    tb = draw(m)
    @test occursin("dash_square", Tachikoma.row_text(tb, find_text(tb, "emptied one cache of").y))

    foreach(dash_square, 1:5)
    press(m, 'E')
    @test isempty(c)

    press(m, 'm')
    @test m.input !== nothing
    press(m, ntuple(_ -> :backspace, 10)..., '1', '_', '0', '0', '0', :enter)
    @test m.input === nothing && Cached.cache_stats(c).maxsize == 1000
    @test only(m.visible).stats.maxsize == 1000
    press(m, 'm', 'x', :enter)
    @test Cached.cache_stats(c).maxsize == 1000 && occursin("invalid maxsize", m.message)
    press(m, 'm', :escape)
    @test m.input === nothing && !m.quit

    # filter through the input line
    m.filter = "dash_"
    Ext.refresh!(m)
    press(m, '/', ntuple(_ -> :backspace, 10)..., 'b', 'y', :enter)
    @test m.filter == "by" && only(m.visible).f === dash_bytes

    press(m, 'q')
    @test Tachikoma.should_quit(m)
end

@testset "refresh picks up new caches and rates" begin
    m = Ext.Dashboard(; interval = 0.0, filter = "dash_late")
    draw(m)
    @test isempty(m.visible)
    dash_late(1)
    dash_late(1.0)
    tb = draw(m)
    @test length(m.visible) == 2
    @test find_text(tb, "Float64") !== nothing

    Ext.refresh!(m, m.lastrefresh + 1)
    foreach(_ -> dash_late(1), 1:4)
    Ext.refresh!(m, m.lastrefresh + 2)
    t = m.trends[only(r.cache for r in m.visible if r.keytype == "Tuple{Int64}")]
    @test t.rates[end] ≈ 2.0 && t.recent == 1.0

    # caches that disappear are dropped
    set_max_subcaches!(dash_late, 1)
    Ext.refresh!(m)
    @test length(m.visible) == 1 && length(m.trends) == length(m.rows)
    @test draw(m) isa TestBackend
end

@testset "byte sizes" begin
    @test Ext._bytes(0) == "0 B" && Ext._bytes(1023) == "1023 B"
    @test Ext._bytes(1024) == "1.0 KiB" && Ext._bytes(1024^2) == "1.0 MiB"
    @test Ext._bytes(64 * 1024^3) == "64.0 GiB" && Ext._bytes(2 * 1024^5) == "2048.0 TiB"
end
