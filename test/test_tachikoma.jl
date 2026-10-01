using Test
using Cached

@testset "dashboard needs Tachikoma" begin
    if Base.get_extension(Cached, :CachedTachikomaExt) === nothing
        @test_throws r"using Tachikoma" cache_dashboard()
    end
end

using Tachikoma: Tachikoma, TestBackend, KeyEvent, Rect, Frame, GraphicsRegion, PixelSnapshot, find_text, row_text

const Ext = Base.get_extension(Cached, :CachedTachikomaExt)

# unique names, as other test files may share this process and its global caches
@cached dash_square(x) = x^2
@cached dash_bytes(n::Int)::Vector{Float64} = zeros(n)
@cached dash_kw(s::Symbol; upper::Bool = false)::String = upper ? uppercase(string(s)) : string(s)
@cached dash_late(x) = x

function draw(m; width = 120, height = 24)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end
press(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)
line(tb, text) = (p = find_text(tb, text); p === nothing ? "" : row_text(tb, p.y))
select!(m, id) = (m.selected = findfirst(l -> Ext._id(first(l)) === id, m.lines); m)
function dashboard(filter)
    m = Ext.Dashboard(; interval = Inf, filter)
    Ext.refresh!(m)
    return m
end

foreach(dash_square, (1, 2, 3, 1, 2, 1.0))
set_cache_size!(dash_bytes, 10^6; by = Cached.cachesize)
dash_bytes(10);
dash_bytes(10);
dash_kw(:a; upper = true)

@testset "signatures and formatting" begin
    @test Ext.signature("f", Tuple{Int, Float64}, String) == "f(::$Int, ::Float64)::String"
    @test Ext.signature("f", Tuple{}, Int) == "f()::$Int"
    @test Ext.signature("f", Tuple{Symbol, @NamedTuple{upper::Bool}}, String) == "f(::Symbol; upper::Bool)::String"
    @test Ext._truncate("abcdefghij", 7) == "abcd…ij"
    @test Ext._truncate("abc", 7) == "abc"
    @test Ext._short(216, false) == "216" && Ext._short(10_000, false) == "10k" && Ext._short(1234, false) == "1.2k"
    @test Ext._short(1023, true) == "1023B" && Ext._short(1024^2, true) == "1.0MiB" && Ext._short(64 * 1024^3, true) == "64GiB"
end

@testset "tree of functions and their caches" begin
    m = dashboard("dash_")
    square = only(r for r in m.rows if r.f === dash_square)
    @test length(square.children) == 2
    @test (square.stats.hits, square.stats.misses, square.stats.length) == (2, 4, 4)
    @test square.stats.maxsize == sum(c -> c.stats.maxsize, square.children)

    tb = draw(m)
    @test find_text(tb, "▾ $(repr(dash_square))") !== nothing
    @test find_text(tb, "(::Float64)::Float64") !== nothing
    @test occursin("33%", line(tb, "▾ $(repr(dash_square))")) # 2 hits, 4 misses
    @test occursin("(::Symbol; upper::Bool)::String", line(tb, "dash_kw"))
    @test occursin(r"\d+B/977KiB", line(tb, "dash_bytes"))
    @test find_text(tb, "Activity") !== nothing && find_text(tb, "q quit") !== nothing

    # fold with ← → and Space; ← on a sub-cache folds its function
    n = length(m.lines)
    select!(m, dash_square)
    press(m, :left)
    @test length(m.lines) == n - 2 && Ext.selected(m).f === dash_square
    @test find_text(draw(m), "▸ $(repr(dash_square)) (2 caches)") !== nothing
    press(m, :right)
    @test length(m.lines) == n
    press(m, ' ')
    @test length(m.lines) == n - 2
    press(m, ' ')
    child = first(square.children).cache
    select!(m, child)
    press(m, :right) # nothing to expand
    @test Ext.selected(m).cache === child
    press(m, :left)
    @test length(m.lines) == n - 2 && Ext.selected(m).f === dash_square
    press(m, :right)

    # sorting by hit rate, descending: dash_bytes (50%) before dash_square (33%)
    press(m, 's', 'r')
    @test first(Ext.SORTS[m.sortcol]) == "Hit rate"
    @test findfirst(l -> first(l).f === dash_bytes, m.lines) < findfirst(l -> first(l).f === dash_square, m.lines)
    press(m, 's', 's', 's', 'r')
    @test m.sortcol == 1 && !m.reverse

    # filter through the input line
    press(m, '/', ntuple(_ -> :backspace, 10)..., 'k', 'w', :enter)
    @test m.filter == "kw" && length(m.lines) == 1
    press(m, 'q')
    @test Tachikoma.should_quit(m)
end

@testset "empty state and small terminals" begin
    m = Ext.Dashboard(; interval = Inf, lastrefresh = time())
    @test find_text(draw(m), "No global caches yet") !== nothing
    press(m, :down, :enter, 'e', :left, ' ', :end_key) # no selection: nothing happens
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
    @test find_text(draw(m; width = 65, height = 15), "Size") !== nothing
    @test find_text(draw(m; width = 65, height = 15), "Activity") === nothing
    @test find_text(draw(m; width = 80, height = 15), "Activity") !== nothing
    @test find_text(draw(m; width = 80, height = 15), "hits/s") === nothing
    @test find_text(draw(m; width = 80, height = 16), "hits/s") !== nothing
end

@testset "empty and resize through key events" begin
    m = dashboard("dash_square")
    a, b = (c.cache for c in first(first(m.lines)).children)

    # a sub-cache, then all caches of the function
    select!(m, a)
    press(m, 'e')
    @test isempty(a) && !isempty(b)
    @test occursin("dash_square", line(draw(m), "emptied"))
    select!(m, dash_square)
    press(m, 'e')
    @test isempty(a) && isempty(b)

    select!(m, a)
    old = Cached.cache_stats(a).maxsize
    press(m, :enter)
    @test m.pending == old
    press(m, :right, :right, :left)
    @test m.pending == 2old
    @test find_text(draw(m), "$(Ext._short(old, false)) → $(Ext._short(2old, false))") !== nothing
    press(m, ']')
    @test m.pending == 2old + round(Int, 2old / 10)
    press(m, :escape)
    @test m.pending === nothing && Cached.cache_stats(a).maxsize == old && !m.quit
    press(m, :enter, :left, :enter)
    @test Cached.cache_stats(a).maxsize == old ÷ 2 && Cached.cache_stats(b).maxsize == old

    # a function: all its caches, current and future
    select!(m, dash_square)
    press(m, :enter, '[', :enter)
    n = Cached.cache_stats(a).maxsize
    @test n < old ÷ 2 && Cached.cache_stats(b).maxsize == n
    dash_square(Int8(1))
    @test all(p -> Cached.cache_stats(last(p)).maxsize == n, cache_info(dash_square))
end

@testset "resizing a byte-measured function keeps its caches" begin
    m = dashboard("dash_bytes")
    c = only(first(only(m.lines)).children).cache
    @test c.by !== nothing && length(c) == 1
    press(m, :enter, :right, :enter)
    @test only(cache_info(dash_bytes)).second === c # not discarded
    @test length(c) == 1 && c.by !== nothing && Cached.cache_stats(c).maxsize == 2 * 10^6
end

@testset "refresh picks up new caches and rates" begin
    m = Ext.Dashboard(; interval = 0.0, filter = "dash_late")
    draw(m)
    @test isempty(m.lines)
    dash_late(1)
    tb = draw(m)
    @test length(m.lines) == 1 && find_text(tb, "dash_late(::$Int)::$Int") !== nothing
    dash_late(1.0)
    draw(m)
    @test length(m.lines) == 3 # the function and its two caches

    Ext.refresh!(m, m.lastrefresh + 1)
    foreach(_ -> dash_late(1), 1:4)
    Ext.refresh!(m, m.lastrefresh + 2)
    late = first(first(m.lines))
    @test late.trend.rates[end] ≈ 2.0 && late.trend.recent == 1.0
    int = only(c for c in late.children if keytype(c.cache) == Tuple{Int})
    @test int.trend.rates[end] ≈ 2.0

    # caches that disappear are dropped
    set_max_subcaches!(dash_late, 1)
    Ext.refresh!(m)
    @test length(m.lines) == 1 && !haskey(m.trends, int.cache)
    @test draw(m) isa TestBackend
end
