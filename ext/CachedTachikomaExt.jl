module CachedTachikomaExt

# Terminal dashboard of the global caches, see `Cached.cache_dashboard`.
#
# Two tabs: the caches in RAM, and the disk caches (SQLite extension). The model keeps its own
# copy of the statistics, re-read from `cache_info`, `cache_stats` and `disk_cache_stats` (which
# reads no files) every `interval` seconds; rendering only reads that copy, so a frame never
# touches a cache. The entries and size on disk come from `disk_cache_info`, read for all disk
# caches on a background task while the Disk tab is shown. Actions (empty, resize) call the
# locked public API and refresh immediately; they act on RAM only.

using Cached: Cached, AbstractCache, cache_info, cache_stats, set_cache_size!
using Tachikoma: Tachikoma, Model, Frame, KeyEvent, Rect, Layout, Vertical, Fixed, Fill,
    split_layout, render, set_string!, set_char!, tstyle, center, right, Block, StatusBar, Span,
    Sparkline, Gauge, Paragraph, TextInput, TabBar, handle_key!, text, app

const STATS = @NamedTuple{hits::Int, misses::Int, length::Int, currentsize::Int, maxsize::Int}
const HISTORY = 120 # refreshes kept for the sparklines
const WINDOW = 10 # refreshes over which the recent hit rate is computed
const MINSIZE = (40, 8) # columns and rows below which only a message is shown
const DISKINTERVAL = 10.0 # seconds between reads of the entries and size on disk

# Hits and misses between successive refreshes, and hits per second.
mutable struct Trend
    hits::Int
    misses::Int
    deltas::Vector{Tuple{Int, Int}}
    rates::Vector{Float64}
end

hitrate(s) = (n = s.hits + s.misses; n == 0 ? NaN : s.hits / n)

# Hits and misses over the last `WINDOW` refreshes, summed so that quiet intervals do not
# weigh in on the recent hit rate (`NaN` without lookups).
function windowed(t::Trend)
    w = @view t.deltas[max(end - WINDOW + 1, 1):end]
    return (; hits = sum(first, w; init = 0), misses = sum(last, w; init = 0))
end
recent(t::Trend) = hitrate(windowed(t))
recent(rows::Vector) = (ws = map(r -> windowed(r.trend), rows); hitrate((; hits = sum(w -> w.hits, ws; init = 0), misses = sum(w -> w.misses, ws; init = 0))))

# A global cache (RAM tab), or the disk cache of a function (Disk tab, without `cache`, with
# the lookups on disk in `stats`), as seen at the last refresh.
struct Row
    f::Any
    cache::Union{Nothing, AbstractCache}
    label::String # the function, as printed
    kind::String
    bytes::Bool
    stats::STATS
    trend::Trend
end

activity(r::Row) = isempty(r.trend.rates) ? 0.0 : r.trend.rates[end]
fill_fraction(s, maxsize = s.maxsize) = maxsize == 0 ? 1.0 : s.currentsize / maxsize
id(r::Row) = r.cache === nothing ? r.f : r.cache

# Columns after the name, dropped from the right as the terminal narrows: a header, a width, a
# function drawing the cell into a rect, and a sort key (or `nothing`).
column(name, width, draw, by = nothing) = (; name, width, draw, by)
const NAME = column("Name", 0, nothing, (m, r) -> r.label)
const HITRATE = column("Hit rate", 13, (rect, buf, r, m) -> render(hitrate_gauge(r), rect, buf), (m, r) -> (h = recent(r.trend); isnan(h) ? -1.0 : h))
const ACTIVITY = column("Activity", 8, (rect, buf, r, m) -> render(Sparkline(r.trend.rates; style = tstyle(:accent)), rect, buf), (m, r) -> activity(r))
const RAMCOLUMNS = (
    HITRATE,
    column("Size", 22, (rect, buf, r, m) -> render(size_gauge(r, m), rect, buf), (m, r) -> fill_fraction(r.stats)),
    column("Kind", 10, (rect, buf, r, m) -> set_string!(buf, rect.x, rect.y, r.kind, tstyle(:text_dim))),
    ACTIVITY,
)
const DISKCOLUMNS = ( # entries and size first, as they matter most and fit in 40 columns
    column("Entries", 8, (rect, buf, r, m) -> disk_cell(m, r, i -> _short(i.entries, false), rect, buf), (m, r) -> disk_key(m, r, :entries)),
    column("Size", 8, (rect, buf, r, m) -> disk_cell(m, r, i -> _short(i.bytes, true), rect, buf), (m, r) -> disk_key(m, r, :bytes)),
    HITRATE,
    ACTIVITY,
)

# The rows of a tab, filtered and sorted into `lines`, and its selection, scroll and order.
@kwdef mutable struct Tab
    title::String
    columns::Tuple
    rows::Vector{Row} = Row[]
    lines::Vector{Row} = Row[]
    selected::Int = 0
    offset::Int = 0
    sortcol::Int = 1
    reverse::Bool = false
end

sorts(t::Tab) = (NAME, filter(c -> c.by !== nothing, t.columns)...)

@kwdef mutable struct Dashboard <: Model
    interval::Float64 = 1.0
    filter::String = ""                             # by function name, on both tabs
    tabs::Vector{Tab} = [Tab(; title = "RAM", columns = RAMCOLUMNS), Tab(; title = "Disk", columns = DISKCOLUMNS)]
    tab::Int = 1                                    # 1: RAM, 2: Disk
    trends::IdDict{Any, Trend} = IdDict{Any, Trend}() # by cache, or by function for the disk
    lastrefresh::Float64 = -Inf
    pending::Union{Nothing, Int} = nothing          # new maxsize while resizing
    input::Union{Nothing, TextInput} = nothing      # filter input
    message::String = ""
    diskinfo::IdDict{Any, Any} = IdDict{Any, Any}() # f => (; path, entries, bytes), or `nothing` if unreadable
    diskread::Float64 = -Inf                        # when the last read of `diskinfo` started
    disktask::Union{Nothing, Task} = nothing        # reading the next `diskinfo`
    quit::Bool = false
end

Tachikoma.should_quit(m::Dashboard) = m.quit

function Cached.cache_dashboard(; interval::Real = 1.0, filter::AbstractString = "")
    m = Dashboard(; interval, filter)
    refresh!(m)
    app(m; fps = 20)
    return nothing
end

current(m::Dashboard) = m.tabs[m.tab]
isdisk(m::Dashboard) = m.tab == 2
selected(m::Dashboard) = (t = current(m); get(t.lines, t.selected, nothing))

# --- refresh ---

function refresh!(m::Dashboard, now = time())
    elapsed = now - m.lastrefresh
    m.lastrefresh = now
    trends = IdDict{Any, Trend}()
    disk = disk_stats()
    m.tabs[1].rows = map(cache_info()) do (f, c)
        st = cache_stats(c)
        s = STATS(st[fieldnames(STATS)])
        kind = (c isa Cached.ClockCache ? "Clock" : string(nameof(typeof(c)))) * (any(d -> first(d) === f, disk) ? "+disk" : "")
        Row(f, c, repr(f), kind, st.by !== nothing, s, trend!(trends, m.trends, c, s, elapsed))
    end
    m.tabs[2].rows = map(disk) do (f, d)
        s = STATS((d.hits, d.misses, 0, 0, 0))
        Row(f, nothing, repr(f), "Disk", false, s, trend!(trends, m.trends, f, s, elapsed))
    end
    m.trends = trends # drops the trends of caches that are gone
    return rebuild!(m)
end

# Without the SQLite extension there are no disk caches.
hassqlite() = applicable(Cached.disk_cache_stats)
disk_stats() = hassqlite() ? Cached.disk_cache_stats() : Pair{Any, @NamedTuple{hits::Int, misses::Int}}[]

function trend!(trends, old, c, s, elapsed)
    t = get(old, c, nothing)
    if t === nothing
        t = Trend(s.hits, s.misses, Tuple{Int, Int}[], Float64[])
    else
        d = (max(s.hits - t.hits, 0), max(s.misses - t.misses, 0))
        push!(t.deltas, d)
        push!(t.rates, elapsed > 0 ? first(d) / elapsed : 0.0)
        length(t.deltas) > HISTORY && (popfirst!(t.deltas); popfirst!(t.rates))
        t.hits, t.misses = s.hits, s.misses
    end
    return trends[c] = t
end

# Filter and sort the rows of each tab into its lines, keeping the selected row selected.
function rebuild!(m::Dashboard)
    for t in m.tabs
        sel = get(t.lines, t.selected, nothing)
        by = sorts(t)[t.sortcol].by
        t.lines = sort!(filter(r -> occursin(m.filter, r.label), t.rows); by = r -> by(m, r), rev = t.reverse)
        i = sel === nothing ? nothing : findfirst(r -> id(r) === id(sel), t.lines)
        t.selected = clamp(something(i, t.selected), min(1, length(t.lines)), length(t.lines))
    end
    return m
end

# --- the entries and size on disk ---

# `missing` until read, `nothing` if it could not be.
diskinfo(m::Dashboard, r::Row) = get(m.diskinfo, r.f, missing)

# Collect a finished read, and start the next one at most every `DISKINTERVAL` seconds, or
# when a disk cache has not been read yet. Counting the entries of a large database (on a
# network file system, or while another process writes) can take a while, so it never runs
# on the frame.
function read_disk!(m::Dashboard)
    task = m.disktask
    if task !== nothing && istaskdone(task)
        m.diskinfo, m.disktask = fetch(task), nothing
        rebuild!(m) # the order may depend on it
    end
    rows = m.tabs[2].rows
    if m.disktask === nothing && !isempty(rows) && (time() - m.diskread >= DISKINTERVAL || any(r -> !haskey(m.diskinfo, r.f), rows))
        m.diskread = time()
        fs = map(r -> r.f, rows)
        m.disktask = Threads.@spawn IdDict{Any, Any}(f => read_diskinfo(f) for f in fs)
    end
    return m
end

function read_diskinfo(f)
    return try
        info = Cached.disk_cache_info(f)
        isempty(info) ? nothing : last(first(info))
    catch
        nothing
    end
end

# A cell of the Disk tab: `…` until read, `?` if it could not be.
function disk_cell(m::Dashboard, r::Row, show, rect::Rect, buf)
    info = diskinfo(m, r)
    s = info === missing ? "…" : info === nothing ? "?" : show(info)
    return set_string!(buf, rect.x, rect.y, s, tstyle(:text); max_x = right(rect))
end
disk_key(m::Dashboard, r::Row, field) = (info = diskinfo(m, r); info isa NamedTuple ? getfield(info, field) : -1)

# --- events ---

function Tachikoma.update!(m::Dashboard, evt::KeyEvent)
    m.input === nothing || return edit_filter!(m, evt)
    m.pending === nothing || return edit_size!(m, evt)
    key, c = evt.key, evt.char
    t, r = current(m), selected(m)
    m.message = ""
    n = length(t.lines)
    if key == :escape || (key == :char && c == 'q')
        m.quit = true
    elseif key in (:tab, :backtab)
        m.tab = mod1(m.tab + 1, length(m.tabs))
    elseif key == :char && c in "12"
        m.tab = c - '0'
    elseif key in (:up, :down, :pageup, :pagedown, :home, :end_key)
        step = (; up = -1, down = 1, pageup = -10, pagedown = 10, home = -n, end_key = n)[key]
        t.selected = clamp(t.selected + step, min(1, n), n)
    elseif key == :char && c == 's'
        t.sortcol = mod1(t.sortcol + 1, length(sorts(t)))
        rebuild!(m)
    elseif key == :char && c == 'r'
        t.reverse = !t.reverse
        rebuild!(m)
    elseif key == :char && c == '/'
        m.input = TextInput(; text = m.filter, label = "Filter: ", focused = true)
    elseif key == :char && c == 'g'
        m.diskread = -Inf
        refresh!(m)
    elseif r === nothing
        nothing
    elseif isdisk(m) && (key == :enter || (key == :char && c == 'e'))
        m.message = "disk caches are persistent and shared: empty them with empty_disk_caches!"
    elseif key == :enter
        m.pending = r.stats.maxsize
    elseif key == :char && c == 'e'
        empty!(r.cache)
        m.message = "emptied $(r.label)" * (endswith(r.kind, "+disk") ? " in RAM; its disk cache is kept" : "")
        refresh!(m)
    end
    return nothing
end

# Resize mode: ← → halve and double, [ ] step by 10%, Enter applies, Esc cancels.
function edit_size!(m::Dashboard, evt::KeyEvent)
    p, key, c = m.pending, evt.key, evt.char
    if key == :escape
        m.pending = nothing
    elseif key == :enter
        m.pending = nothing
        r = selected(m)
        r === nothing || resize_row!(m, r, p)
    elseif key == :left
        m.pending = max(p ÷ 2, 1)
    elseif key == :right
        m.pending = 2 * max(p, 1)
    elseif key == :char && c in "[]"
        m.pending = max(p + (c == ']' ? 1 : -1) * max(round(Int, p / 10), 1), 0)
    end
    return nothing
end

# The limit is set for the function, so that it persists, in its current measure
# (`set_cache_size!` would discard the cache if `by` changed).
function resize_row!(m::Dashboard, r::Row, n::Int)
    set_cache_size!(r.f, n; by = Cached.cache_stats(r.cache).by)
    m.message = "set the limit of $(r.label) to $(_short(n, r.bytes))"
    return refresh!(m)
end

function edit_filter!(m::Dashboard, evt::KeyEvent)
    if evt.key == :escape
        m.input = nothing
    elseif evt.key == :enter
        m.filter = strip(text(m.input))
        m.input = nothing
        rebuild!(m)
    else
        handle_key!(m.input, evt)
    end
    return nothing
end

# --- view ---

function Tachikoma.view(m::Dashboard, f::Frame)
    time() - m.lastrefresh >= m.interval && refresh!(m)
    isdisk(m) && read_disk!(m)
    area, buf = f.area, f.buffer
    if area.width < MINSIZE[1] || area.height < MINSIZE[2]
        msg = "terminal too small (need $(MINSIZE[1])×$(MINSIZE[2]))"
        r = center(area, min(length(msg), area.width), 1)
        set_string!(buf, r.x, r.y, msg, tstyle(:warning, bold = true); max_x = right(r))
        return
    end
    t, r = current(m), selected(m)
    detail = area.height < 16 ? 0 : 5
    tabs, header, body, info, status = split_layout(Layout(Vertical, [Fixed(1), Fixed(1), Fill(), Fixed(detail), Fixed(1)]), area)

    render(TabBar([t.title for t in m.tabs]; active = m.tab), tabs, buf)
    set_string!(buf, header.x, header.y, " " * totals(m), tstyle(:title, bold = true); max_x = right(header))

    if isempty(t.lines)
        msg = !isempty(t.rows) ? "No caches match the filter." :
            !isdisk(m) ? "No global caches yet. Call a @cached function." :
            hassqlite() ? "No disk caches open yet. Call a function with a DiskCache." : "Load SQLite.jl (using SQLite) to use disk caches."
        set_string!(buf, body.x + 1, body.y, msg, tstyle(:text_dim); max_x = right(body))
    else
        render_table(m, t, body, buf)
    end
    detail > 0 && r !== nothing && render_detail(m, r, info, buf)
    render_status(m, status, buf)
    return nothing
end

# The header of the current tab, over all its rows (also those hidden by the filter).
function totals(m::Dashboard)
    rows = current(m).rows
    filt = isempty(m.filter) ? "" : " · filter \"$(m.filter)\""
    if !isdisk(m)
        bytes = filter(r -> r.bytes, rows)
        size = isempty(bytes) ? "" : " · $(_short(sum(r -> r.stats.currentsize, bytes), true)) in byte-measured caches"
        return "$(length(rows)) caches · $(sum(r -> r.stats.length, rows; init = 0)) entries$size · recent hit rate $(_percent(recent(rows)))$filt"
    end
    hassqlite() || return "no disk caches: SQLite.jl is not loaded"
    infos = map(r -> diskinfo(m, r), rows)
    known = filter(i -> i isa NamedTuple, infos)
    stored = any(ismissing, infos) ? "… entries · …" :
        "$(sum(i -> i.entries, known; init = 0)) entries · $(_short(sum(i -> i.bytes, known; init = 0), true))"
    hits, misses = sum(r -> r.stats.hits, rows; init = 0), sum(r -> r.stats.misses, rows; init = 0)
    off = Cached.DISK_ENABLED[] ? "" : " · disk caches off"
    return "$(length(rows)) disk caches · $stored · $hits hits · $misses misses ($(_percent(hitrate((; hits, misses)))))$off$filt"
end

const MINNAME = 20 # width of the name column below which columns are dropped

function render_table(m::Dashboard, t::Tab, area::Rect, buf)
    widths = cumsum([c.width + 1 for c in t.columns])
    k = count(<=(area.width - 1 - MINNAME), widths)
    # as wide as the longest label (over all lines, so that scrolling keeps the layout), and
    # any spare width is left at the right
    longest = maximum(r -> textwidth(r.label), t.lines; init = 0)
    namewidth = clamp(longest, MINNAME, area.width - 1 - (k == 0 ? 0 : widths[k]))
    cells = ((; NAME..., width = namewidth), t.columns[1:k]...)
    xs = [area.x + 1; [area.x + namewidth + 2 + (j == 1 ? 0 : widths[j - 1]) for j in 1:k]]

    sorted, arrow = sorts(t)[t.sortcol].name, t.reverse ? " ▼" : " ▲"
    for (c, x) in zip(cells, xs)
        set_string!(buf, x, area.y, c.name == sorted ? c.name * arrow : c.name, tstyle(:title, bold = true); max_x = x + c.width - 1)
    end

    height = area.height - 1
    # keep the selection visible, without blank rows below while rows above are hidden
    t.offset = clamp(t.offset, max(t.selected - height, 0), max(min(t.selected - 1, length(t.lines) - height), 0))
    for (i, r) in enumerate(t.lines[(t.offset + 1):min(end, t.offset + height)])
        y = area.y + i
        issel = t.offset + i == t.selected
        style = issel ? tstyle(:accent, bold = true) : tstyle(:text)
        issel && set_char!(buf, area.x, y, '▌', style)
        set_string!(buf, area.x + 1, y, _truncate(r.label, namewidth), style)
        for (c, x) in zip(cells[2:end], xs[2:end])
            c.draw(Rect(x, y, c.width, 1), buf, r, m)
        end
    end
    return
end

# The recent hit rate, coloured by health; empty with `-` without lookups.
function hitrate_gauge(r::Row)
    h = recent(r.trend)
    isnan(h) && return Gauge(0.0; label = "-")
    return Gauge(h; label = "$(round(Int, 100h))%", filled_style = tstyle(h < 0.5 ? :error : h < 0.8 ? :warning : :success))
end

# The fill against the limit, or against the pending limit while resizing this row.
function size_gauge(r::Row, m::Dashboard)
    resizing = m.pending !== nothing && selected(m) === r
    maxsize = resizing ? m.pending : r.stats.maxsize
    frac = fill_fraction(r.stats, maxsize)
    style = resizing ? tstyle(:accent, bold = true) : tstyle(frac >= 0.9 ? :warning : :primary)
    label = "$(_short(r.stats.currentsize, r.bytes))/$(_short(maxsize, r.bytes))"
    return Gauge(frac; label, filled_style = style)
end

function render_detail(m::Dashboard, r::Row, area::Rect, buf)
    inner = render(Block(; title = " $(_truncate(r.label, area.width - 6)) ", border_style = tstyle(:border)), area, buf)
    s, t = r.stats, r.trend
    rates = "hit rate: recent $(_percent(recent(t))) · lifetime $(_percent(hitrate(s))) · $(round(activity(r); digits = 1)) hits/s"
    lines = if isdisk(m)
        info = diskinfo(m, r)
        stored = info === missing ? "… entries" : info === nothing ? "? entries (could not be read)" :
            "$(info.entries) entries · $(_short(info.bytes, true)) · $(info.path)"
        [stored, "$(s.hits) hits · $(s.misses) misses in this process · $rates"]
    else
        size = r.bytes ? "$(s.length) entries, $(_short(s.currentsize, true)) of $(_short(s.maxsize, true))" :
            "$(s.length) of $(s.maxsize) entries"
        ["$(r.kind) · $size · $(s.hits) hits · $(s.misses) misses", rates]
    end
    # cut in the middle rather than wrapped, which keeps the end of the path
    render(Paragraph(join(_truncate.(lines, inner.width), "\n"); style = tstyle(:text)), Rect(inner.x, inner.y, inner.width, 2), buf)
    render(Sparkline(t.rates; style = tstyle(:accent)), Rect(inner.x, inner.y + 2, inner.width, 1), buf)
    return
end

const KEYS = "⇥ tab  ↑↓ select  ⏎ resize  e empty  s sort  r reverse  / filter  g refresh  q quit"
const DISKKEYS = "⇥ tab  ↑↓ select  s sort  r reverse  / filter  g refresh  q quit"
const RESIZEKEYS = "←→ ½ ×2  [ ] ±10%  ⏎ apply  Esc cancel"

function render_status(m::Dashboard, area::Rect, buf)
    r = selected(m)
    if m.input !== nothing
        render(m.input, area, buf)
    elseif m.pending !== nothing && r !== nothing
        change = " $(_short(r.stats.maxsize, r.bytes)) → $(_short(m.pending, r.bytes)) "
        left = [Span(change, tstyle(:accent, bold = true)), Span(" $(r.label) ", tstyle(:text)), Span(" $RESIZEKEYS", tstyle(:text_dim))]
        render(StatusBar(; left), area, buf)
    else
        # a message replaces the keybindings until the next key
        left = isempty(m.message) ? Span(" $(isdisk(m) ? DISKKEYS : KEYS) ", tstyle(:text_dim)) : Span(" $(m.message) ", tstyle(:warning))
        render(StatusBar(; left = [left]), area, buf)
    end
    return
end

# --- formatting ---

_percent(x) = isnan(x) ? "-" : string(round(100x; digits = 1), "%")

# At most `w` columns wide, cutting the middle so that both ends of a name stay visible.
function _truncate(s::AbstractString, w::Integer)
    textwidth(s) <= w && return s
    w <= 0 && return ""
    tail = (w - 1) ÷ 3
    return _fit(s, w - 1 - tail) * "…" * reverse(_fit(reverse(s), tail))
end

# The longest prefix of `s` at most `w` columns wide.
function _fit(s::AbstractString, w::Integer)
    n = 0
    for (i, c) in pairs(s)
        n += textwidth(c)
        n > w && return s[1:prevind(s, i)]
    end
    return s
end

# 216, 1.2k, 10k, 3.4M; or 512B, 1.5KiB, 976KiB, 64GiB
function _short(n::Integer, bytes::Bool)
    base, units = bytes ? (1024, ("B", "KiB", "MiB", "GiB", "TiB")) : (1000, ("", "k", "M", "G", "T"))
    x, i = float(n), 1
    while x >= base && i < length(units)
        x /= base
        i += 1
    end
    return string(i == 1 || x >= 10 ? round(Int, x) : round(x; digits = 1), units[i])
end

end # module CachedTachikomaExt
