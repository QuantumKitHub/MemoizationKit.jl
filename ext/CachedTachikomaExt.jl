module CachedTachikomaExt

# Terminal dashboard of the global caches, see `Cached.cache_dashboard`.
#
# The model keeps its own copy of the statistics, re-read from `cache_info` and `cache_stats`
# every `interval` seconds; rendering only reads that copy, so a frame never touches a cache.
# Actions (empty, resize) call the locked public API and refresh immediately.

using Cached: Cached, AbstractCache, cache_info, cache_stats, empty_caches!
using Tachikoma: Tachikoma, Model, Frame, KeyEvent, Rect, Layout, Vertical, Fixed, Fill,
    split_layout, render, set_string!, tstyle, Block, StatusBar, Span, Sparkline, TextInput,
    DataTable, DataColumn, col_left, col_right, sort_asc, sort_desc, handle_key!, text, app

const STATS = @NamedTuple{hits::Int, misses::Int, length::Int, currentsize::Int, maxsize::Int}
const HISTORY = 120 # samples kept for the sparkline

# One global cache, as seen at the last refresh.
struct Row
    f::Any
    cache::AbstractCache
    name::String
    keytype::String
    valtype::String
    container::String
    bytes::Bool
    stats::STATS
end

hitrate(s) = (n = s.hits + s.misses; n == 0 ? NaN : s.hits / n)
fill_fraction(s) = s.maxsize == 0 ? 0.0 : s.currentsize / s.maxsize

# Hits per second between successive refreshes, for the sparkline.
mutable struct Trend
    hits::Int
    misses::Int
    rates::Vector{Float64}
    recent::Float64 # hit rate over the last interval
end

# Columns: header, cell text, sort key (`r` is a `Row`), alignment. The long type names come
# last, so that narrow terminals still show the statistics.
const COLUMNS = (
    ("Function", r -> r.name, r -> r.name, col_left),
    ("Kind", r -> r.container, r -> r.container, col_left),
    ("Size", r -> _size(r), r -> fill_fraction(r.stats), col_right),
    ("Hits", r -> string(r.stats.hits), r -> r.stats.hits, col_right),
    ("Misses", r -> string(r.stats.misses), r -> r.stats.misses, col_right),
    ("Hit rate", r -> _percent(hitrate(r.stats)), r -> (h = hitrate(r.stats); isnan(h) ? -1.0 : h), col_right),
    ("Key", r -> r.keytype, r -> r.keytype, col_left),
    ("Value", r -> r.valtype, r -> r.valtype, col_left),
)

@kwdef mutable struct Dashboard <: Model
    interval::Float64 = 1.0
    filter::String = ""
    rows::Vector{Row} = Row[]         # every global cache
    visible::Vector{Row} = Row[]      # filtered and sorted, as shown in `table`
    trends::IdDict{AbstractCache, Trend} = IdDict{AbstractCache, Trend}()
    table::DataTable = DataTable(DataColumn[])
    sortcol::Int = 1
    reverse::Bool = false
    lastrefresh::Float64 = -Inf
    input::Union{Nothing, TextInput} = nothing
    mode::Symbol = :normal            # :resize or :filter while `input` is open
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

selected(m::Dashboard) = get(m.visible, m.table.selected, nothing)

# --- refresh ---

function refresh!(m::Dashboard, now = time())
    elapsed = now - m.lastrefresh
    m.lastrefresh = now
    trends = IdDict{AbstractCache, Trend}()
    m.rows = map(cache_info()) do (f, c)
        s = STATS(cache_stats(c))
        t = get(m.trends, c, nothing)
        if t === nothing
            t = Trend(s.hits, s.misses, Float64[], NaN)
        else
            dh, dm = max(s.hits - t.hits, 0), max(s.misses - t.misses, 0)
            push!(t.rates, elapsed > 0 ? dh / elapsed : 0.0)
            length(t.rates) > HISTORY && popfirst!(t.rates)
            t.recent = dh + dm == 0 ? NaN : dh / (dh + dm)
            t.hits, t.misses = s.hits, s.misses
        end
        trends[c] = t
        container = c isa Cached.LRU ? "LRU" : c isa Cached.ClockCache ? "Clock" : string(nameof(typeof(c)))
        Row(f, c, repr(f), string(keytype(c)), string(valtype(c)), container, c.by !== nothing, s)
    end
    m.trends = trends # drops the trends of caches that are gone
    return rebuild!(m)
end

# Filter and sort `rows` into `visible`, keeping the selected cache selected if it is still there.
function rebuild!(m::Dashboard)
    current = selected(m)
    key = COLUMNS[m.sortcol][3]
    rows = filter(r -> occursin(m.filter, r.name), m.rows)
    sort!(rows; by = key, rev = m.reverse)
    m.visible = rows
    columns = [DataColumn(name, map(cell, rows); align) for (name, cell, _, align) in COLUMNS]
    i = current === nothing ? nothing : findfirst(r -> r.cache === current.cache, rows)
    i = clamp(something(i, m.table.selected), min(1, length(rows)), length(rows))
    table = DataTable(columns; selected = i)
    table.offset = m.table.offset
    table.sort_col, table.sort_dir = m.sortcol, m.reverse ? sort_desc : sort_asc
    m.table = table
    return m
end

# --- events ---

function Tachikoma.update!(m::Dashboard, evt::KeyEvent)
    m.input === nothing || return edit!(m, evt)
    key, c = evt.key, evt.char
    r = selected(m)
    m.message = ""
    if key == :escape || (key == :char && c == 'q')
        m.quit = true
    elseif key == :char && c == 's'
        m.sortcol = mod1(m.sortcol + 1, length(COLUMNS))
        rebuild!(m)
    elseif key == :char && c == 'r'
        m.reverse = !m.reverse
        rebuild!(m)
    elseif key == :char && c == '/'
        open_input!(m, :filter, m.filter)
    elseif key == :char && c == 'g'
        refresh!(m)
    elseif r === nothing
        handle_key!(m.table, evt)
    elseif key == :char && c == 'e'
        empty!(r.cache)
        m.message = "emptied one cache of $(r.name)"
        refresh!(m)
    elseif key == :char && c == 'E'
        empty_caches!(r.f)
        m.message = "emptied all caches of $(r.name)"
        refresh!(m)
    elseif key == :char && c == 'm'
        open_input!(m, :resize, string(r.stats.maxsize))
    else
        handle_key!(m.table, evt)
    end
    return nothing
end

function open_input!(m::Dashboard, mode::Symbol, initial::AbstractString)
    label = mode === :filter ? "Filter: " : "New maxsize: "
    m.input = TextInput(; text = initial, label, focused = true)
    m.mode = mode
    return m
end

# Keys while the input line is open: Enter applies, Esc cancels.
function edit!(m::Dashboard, evt::KeyEvent)
    if evt.key == :escape
        m.input = nothing
    elseif evt.key == :enter
        s = strip(text(m.input))
        m.input = nothing
        m.mode === :filter ? (m.filter = s; rebuild!(m)) : apply_resize!(m, s)
    else
        handle_key!(m.input, evt)
    end
    return nothing
end

function apply_resize!(m::Dashboard, s::AbstractString)
    r = selected(m)
    r === nothing && return m
    n = tryparse(Int, replace(s, '_' => ""))
    if n === nothing || n < 0
        m.message = "invalid maxsize $(repr(s)): expected a non-negative integer"
        return m
    end
    resize!(r.cache; maxsize = n)
    m.message = "resized one cache of $(r.name) to $(r.bytes ? _bytes(n) : "$n entries")"
    return refresh!(m)
end

# --- view ---

function Tachikoma.view(m::Dashboard, f::Frame)
    time() - m.lastrefresh >= m.interval && refresh!(m)
    area, buf = f.area, f.buffer
    (area.width < 1 || area.height < 1) && return
    detail = area.height >= 12 ? 4 : 0
    rows = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(detail), Fixed(1)]), area)
    length(rows) == 4 || return
    header, body, info, status = rows

    entries = sum(r -> r.stats.length, m.rows; init = 0)
    order = string(COLUMNS[m.sortcol][1], m.reverse ? " ▼" : " ▲")
    filt = isempty(m.filter) ? "" : " · filter \"$(m.filter)\""
    set_string!(
        buf, header.x, header.y, " $(length(m.rows)) caches, $entries entries · sorted by $order$filt",
        tstyle(:title, bold = true); max_x = header.x + header.width - 1
    )

    if isempty(m.visible)
        msg = isempty(m.rows) ? "No global caches yet. Call a @cached function." : "No caches match the filter."
        body.height >= 1 && set_string!(buf, body.x + 1, body.y, msg, tstyle(:text_dim); max_x = body.x + body.width - 1)
    else
        render(m.table, body, buf)
    end

    r = selected(m)
    detail > 0 && r !== nothing && render_detail(m, r, info, buf)
    render_status(m, status, buf)
    return nothing
end

function render_detail(m::Dashboard, r::Row, area::Rect, buf)
    t = get(m.trends, r.cache, nothing)
    inner = render(Block(; title = " $(r.name) · $(r.keytype) ", border_style = tstyle(:border)), area, buf)
    (inner.width < 1 || inner.height < 2) && return
    rate = t === nothing || isempty(t.rates) ? 0.0 : t.rates[end]
    recent = t === nothing ? NaN : t.recent
    line = "$(_compact(r)) · $(round(rate; digits = 1)) hits/s · recent hit rate $(_percent(recent))"
    set_string!(buf, inner.x, inner.y, line, tstyle(:text); max_x = inner.x + inner.width - 1)
    t === nothing || render(Sparkline(t.rates; style = tstyle(:accent)), Rect(inner.x, inner.y + 1, inner.width, 1), buf)
    return
end

const KEYS = "↑↓ select  s sort  r reverse  / filter  e empty  E empty function  m maxsize  q quit"

function render_status(m::Dashboard, area::Rect, buf)
    if m.input !== nothing
        render(m.input, area, buf)
    else
        # a message replaces the keybindings until the next key
        left = isempty(m.message) ? Span(" $KEYS ", tstyle(:text_dim)) : Span(" $(m.message) ", tstyle(:warning))
        render(StatusBar(; left = [left]), area, buf)
    end
    return
end

# --- formatting ---

_percent(x) = isnan(x) ? "-" : string(round(100x; digits = 1), "%")

function _bytes(n::Integer)
    i = clamp(fld(ndigits(n; base = 2) - 1, 10), 0, 4) # 1024^i <= n
    i == 0 && return "$n B"
    return string(round(n / 1024^i; digits = 1), " ", ("KiB", "MiB", "GiB", "TiB")[i])
end

_size(r::Row) = r.bytes ? "$(_bytes(r.stats.currentsize))/$(_bytes(r.stats.maxsize))" :
    "$(r.stats.length)/$(r.stats.maxsize)"

function _compact(r::Row)
    s = r.stats
    return r.bytes ? "$(s.length) entries, $(_bytes(s.currentsize)) of $(_bytes(s.maxsize))" :
        "$(s.length) of $(s.maxsize) entries"
end

end # module CachedTachikomaExt
