module CachedTachikomaExt

# Terminal dashboard of the global caches, see `Cached.cache_dashboard`.
#
# The model keeps its own copy of the statistics, re-read from `cache_info` and `cache_stats`
# every `interval` seconds; rendering only reads that copy, so a frame never touches a cache.
# Actions (empty, resize) call the locked public API and refresh immediately.

using Cached: Cached, AbstractCache, cache_info, cache_stats, set_cache_size!
using Tachikoma: Tachikoma, Model, Frame, KeyEvent, Rect, Layout, Vertical, Fixed, Fill,
    split_layout, render, set_string!, set_char!, tstyle, center, right, Block, StatusBar, Span,
    Sparkline, TextInput, BARS_H, handle_key!, text, app

const STATS = @NamedTuple{hits::Int, misses::Int, length::Int, currentsize::Int, maxsize::Int}
const HISTORY = 120 # refreshes kept for the sparklines
const WINDOW = 10 # refreshes over which the recent hit rate is computed
const MINSIZE = (40, 8) # columns and rows below which only a message is shown

# Hits and misses between successive refreshes, and hits per second.
mutable struct Trend
    hits::Int
    misses::Int
    deltas::Vector{Tuple{Int, Int}}
    rates::Vector{Float64}
end

# Hit rate over the last `WINDOW` refreshes, from the summed deltas so that quiet intervals
# do not weigh in; `NaN` without lookups.
function recent(t::Trend)
    window = @view t.deltas[max(end - WINDOW + 1, 1):end]
    h, m = sum(first, window; init = 0), sum(last, window; init = 0)
    return h + m == 0 ? NaN : h / (h + m)
end

# One global cache, as seen at the last refresh.
struct Row
    f::Any
    cache::AbstractCache
    label::String # the function, as printed
    kind::String
    bytes::Bool
    stats::STATS
    trend::Trend
end

hitrate(s) = (n = s.hits + s.misses; n == 0 ? NaN : s.hits / n)
activity(r::Row) = isempty(r.trend.rates) ? 0.0 : r.trend.rates[end]
fill_fraction(s, maxsize = s.maxsize) = maxsize == 0 ? 1.0 : s.currentsize / maxsize

# Sort orders, by key on a `Row`; the last three are also the optional table columns.
const SORTS = (
    "Name" => r -> r.label,
    "Hit rate" => r -> (h = recent(r.trend); isnan(h) ? -1.0 : h),
    "Size" => r -> fill_fraction(r.stats),
    "Activity" => activity,
)

@kwdef mutable struct Dashboard <: Model
    interval::Float64 = 1.0
    filter::String = ""
    rows::Vector{Row} = Row[]                     # every global cache, as read at the last refresh
    lines::Vector{Row} = Row[]                    # filtered and sorted, as shown
    trends::IdDict{AbstractCache, Trend} = IdDict{AbstractCache, Trend}()
    selected::Int = 0
    offset::Int = 0
    sortcol::Int = 1
    reverse::Bool = false
    lastrefresh::Float64 = -Inf
    pending::Union{Nothing, Int} = nothing        # new maxsize while resizing
    input::Union{Nothing, TextInput} = nothing    # filter input
    message::String = ""
    quit::Bool = false
end

Tachikoma.should_quit(m::Dashboard) = m.quit

function dashboard(; interval::Real = 1.0, filter::AbstractString = "")
    m = Dashboard(; interval, filter)
    refresh!(m)
    app(m; fps = 20)
    return nothing
end

selected(m::Dashboard) = get(m.lines, m.selected, nothing)

# --- refresh ---

function refresh!(m::Dashboard, now = time())
    elapsed = now - m.lastrefresh
    m.lastrefresh = now
    trends = IdDict{AbstractCache, Trend}()
    m.rows = map(cache_info()) do (f, c)
        s = STATS(cache_stats(c))
        kind = c isa Cached.LRU ? "LRU" : c isa Cached.ClockCache ? "Clock" : string(nameof(typeof(c)))
        Row(f, c, repr(f), kind, c.by !== nothing, s, trend!(trends, m.trends, c, s, elapsed))
    end
    m.trends = trends # drops the trends of caches that are gone
    return rebuild!(m)
end

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

# Filter and sort `rows` into `lines`, keeping the selected cache selected.
function rebuild!(m::Dashboard)
    current = selected(m)
    m.lines = sort!(filter(r -> occursin(m.filter, r.label), m.rows); by = last(SORTS[m.sortcol]), rev = m.reverse)
    i = current === nothing ? nothing : findfirst(r -> r.cache === current.cache, m.lines)
    m.selected = clamp(something(i, m.selected), min(1, length(m.lines)), length(m.lines))
    return m
end

# --- events ---

function Tachikoma.update!(m::Dashboard, evt::KeyEvent)
    m.input === nothing || return edit_filter!(m, evt)
    m.pending === nothing || return edit_size!(m, evt)
    key, c = evt.key, evt.char
    r = selected(m)
    m.message = ""
    n = length(m.lines)
    if key == :escape || (key == :char && c == 'q')
        m.quit = true
    elseif key in (:up, :down, :pageup, :pagedown, :home, :end_key)
        step = (; up = -1, down = 1, pageup = -10, pagedown = 10, home = -n, end_key = n)[key]
        m.selected = clamp(m.selected + step, min(1, n), n)
    elseif key == :char && c == 's'
        m.sortcol = mod1(m.sortcol + 1, length(SORTS))
        rebuild!(m)
    elseif key == :char && c == 'r'
        m.reverse = !m.reverse
        rebuild!(m)
    elseif key == :char && c == '/'
        m.input = TextInput(; text = m.filter, label = "Filter: ", focused = true)
    elseif key == :char && c == 'g'
        refresh!(m)
    elseif r === nothing
        nothing
    elseif key == :enter
        m.pending = r.stats.maxsize
    elseif key == :char && c == 'e'
        empty!(r.cache)
        m.message = "emptied $(r.label)"
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
    set_cache_size!(r.f, n; by = r.cache.by)
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
    area, buf = f.area, f.buffer
    if area.width < MINSIZE[1] || area.height < MINSIZE[2]
        msg = "terminal too small (need $(MINSIZE[1])×$(MINSIZE[2]))"
        r = center(area, min(length(msg), area.width), 1)
        set_string!(buf, r.x, r.y, msg, tstyle(:warning, bold = true); max_x = right(r))
        return
    end
    detail = area.height >= 16 ? 5 : 0
    header, body, info, status = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(detail), Fixed(1)]), area)

    entries = sum(r -> r.stats.length, m.rows; init = 0)
    filt = isempty(m.filter) ? "" : " · filter \"$(m.filter)\""
    title = " $(length(m.rows)) caches, $entries entries$filt"
    set_string!(buf, header.x, header.y, title, tstyle(:title, bold = true); max_x = right(header))

    if isempty(m.lines)
        msg = isempty(m.rows) ? "No global caches yet. Call a @cached function." : "No caches match the filter."
        set_string!(buf, body.x + 1, body.y, msg, tstyle(:text_dim); max_x = right(body))
    else
        render_table(m, body, buf)
    end
    r = selected(m)
    detail > 0 && r !== nothing && render_detail(r, info, buf)
    render_status(m, status, buf)
    return nothing
end

# Optional columns, dropped from the right as the terminal narrows: header, width, cell.
const COLUMNS = (
    ("Hit rate", 13, (buf, x, y, r, m) -> draw_hitrate(buf, x, y, r)),
    ("Size", 22, (buf, x, y, r, m) -> draw_size(buf, x, y, r, m)),
    ("Kind", 5, (buf, x, y, r, m) -> set_string!(buf, x, y, r.kind, tstyle(:text_dim))),
    ("Activity", 8, (buf, x, y, r, m) -> render(Sparkline(r.trend.rates; style = tstyle(:accent)), Rect(x, y, 8, 1), buf)),
)
const MINNAME = 20 # width of the name column below which columns are dropped

function render_table(m::Dashboard, area::Rect, buf)
    k = 0
    while k < length(COLUMNS) && area.width - 1 - sum(c -> c[2] + 1, COLUMNS[1:(k + 1)]) >= MINNAME
        k += 1
    end
    columns = COLUMNS[1:k]
    # as wide as the longest label (over all lines, so that scrolling keeps the layout), and
    # any spare width is left at the right
    longest = maximum(r -> textwidth(r.label), m.lines; init = 0)
    namewidth = clamp(longest, MINNAME, area.width - 1 - sum(c -> c[2] + 1, columns; init = 0))

    sorted, arrow = first(SORTS[m.sortcol]), m.reverse ? " ▼" : " ▲"
    x = area.x + 1
    for (name, w, _) in (("Name", namewidth, nothing), columns...)
        set_string!(buf, x, area.y, name == sorted ? name * arrow : name, tstyle(:title, bold = true); max_x = x + w - 1)
        x += w + 1
    end

    height = area.height - 1
    # keep the selection visible, without blank rows below while rows above are hidden
    m.offset = clamp(m.offset, max(m.selected - height, 0), max(min(m.selected - 1, length(m.lines) - height), 0))
    for (i, r) in enumerate(m.lines[(m.offset + 1):min(end, m.offset + height)])
        y = area.y + i
        issel = m.offset + i == m.selected
        style = issel ? tstyle(:accent, bold = true) : tstyle(:text)
        issel && set_char!(buf, area.x, y, '▌', style)
        set_string!(buf, area.x + 1, y, _truncate(r.label, namewidth), style)
        x = area.x + namewidth + 2
        for (_, w, draw) in columns
            draw(buf, x, y, r, m)
            x += w + 1
        end
    end
    return
end

function bar!(buf, x, y, w, frac, style)
    n = clamp(frac, 0.0, 1.0) * w
    full, part = floor(Int, n), round(Int, (n - floor(n)) * 8)
    for i in 0:(w - 1)
        filled = i < full || (i == full && part > 0)
        set_char!(buf, x + i, y, i < full ? '█' : filled ? BARS_H[part] : '·', filled ? style : tstyle(:text_dim))
    end
    return
end

function draw_hitrate(buf, x, y, r::Row)
    h = recent(r.trend)
    style = isnan(h) ? tstyle(:text_dim) : tstyle(h < 0.5 ? :error : h < 0.8 ? :warning : :success)
    bar!(buf, x, y, 8, isnan(h) ? 0.0 : h, style)
    set_string!(buf, x + 9, y, isnan(h) ? "   -" : lpad("$(round(Int, 100h))%", 4), style)
    return
end

# The fill against the limit, or against the pending limit while resizing this row.
function draw_size(buf, x, y, r::Row, m::Dashboard)
    resizing = m.pending !== nothing && selected(m) === r
    maxsize = resizing ? m.pending : r.stats.maxsize
    frac = fill_fraction(r.stats, maxsize)
    style = resizing ? tstyle(:accent, bold = true) : tstyle(frac >= 0.9 ? :warning : :primary)
    bar!(buf, x, y, 8, frac, style)
    label = "$(_short(r.stats.currentsize, r.bytes))/$(_short(maxsize, r.bytes))"
    set_string!(buf, x + 9, y, label, style; max_x = x + 21)
    return
end

function render_detail(r::Row, area::Rect, buf)
    inner = render(Block(; title = " $(_truncate(r.label, area.width - 6)) ", border_style = tstyle(:border)), area, buf)
    s, t = r.stats, r.trend
    size = r.bytes ? "$(s.length) entries, $(_short(s.currentsize, true)) of $(_short(s.maxsize, true))" :
        "$(s.length) of $(s.maxsize) entries"
    lines = (
        "$(r.kind) · $size · $(s.hits) hits · $(s.misses) misses",
        "hit rate: recent $(_percent(recent(t))) · lifetime $(_percent(hitrate(s))) · $(round(activity(r); digits = 1)) hits/s",
    )
    for (i, line) in enumerate(lines)
        set_string!(buf, inner.x, inner.y + i - 1, line, tstyle(:text); max_x = right(inner))
    end
    render(Sparkline(t.rates; style = tstyle(:accent)), Rect(inner.x, inner.y + 2, inner.width, 1), buf)
    return
end

const KEYS = "↑↓ select  ⏎ resize  e empty  s sort  r reverse  / filter  q quit"
const RESIZEKEYS = "←→ ½ ×2  [ ] ±10%  ⏎ apply  Esc cancel"

function render_status(m::Dashboard, area::Rect, buf)
    r = selected(m)
    if m.input !== nothing
        render(m.input, area, buf)
    elseif m.pending !== nothing && r !== nothing
        change = " $(_short(r.stats.maxsize, r.bytes)) → $(_short(m.pending, r.bytes)) "
        what = " $(r.label) "
        left = [Span(change, tstyle(:accent, bold = true)), Span(what, tstyle(:text)), Span(" $RESIZEKEYS", tstyle(:text_dim))]
        render(StatusBar(; left), area, buf)
    else
        # a message replaces the keybindings until the next key
        left = isempty(m.message) ? Span(" $KEYS ", tstyle(:text_dim)) : Span(" $(m.message) ", tstyle(:warning))
        render(StatusBar(; left = [left]), area, buf)
    end
    return
end

# --- formatting ---

_percent(x) = isnan(x) ? "-" : string(round(100x; digits = 1), "%")

# At most `w` characters, cutting the middle so that both ends of a name stay visible.
function _truncate(s::AbstractString, w::Integer)
    length(s) <= w && return s
    w <= 1 && return first(s, max(w, 0))
    tail = (w - 1) ÷ 3
    return first(s, w - 1 - tail) * "…" * last(s, tail)
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
