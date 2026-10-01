module CachedTachikomaExt

# Terminal dashboard of the global caches, see `Cached.cache_dashboard`.
#
# The model keeps its own copy of the statistics, re-read from `cache_info` and `cache_stats`
# every `interval` seconds; rendering only reads that copy, so a frame never touches a cache.
# Actions (empty, resize) call the locked public API and refresh immediately.

using Cached: Cached, AbstractCache, cache_info, cache_stats, empty_caches!, set_cache_size!
using Tachikoma: Tachikoma, Model, Frame, KeyEvent, Rect, Layout, Vertical, Fixed, Fill,
    split_layout, render, set_string!, set_char!, tstyle, center, right, Block, StatusBar, Span,
    Sparkline, TextInput, BARS_H, handle_key!, text, app

const STATS = @NamedTuple{hits::Int, misses::Int, length::Int, currentsize::Int, maxsize::Int}
const HISTORY = 120 # refreshes kept for the sparklines
const MINSIZE = (40, 8) # columns and rows below which only a message is shown

# Hits per second between successive refreshes.
mutable struct Trend
    hits::Int
    misses::Int
    rates::Vector{Float64}
    recent::Float64 # hit rate over the last interval
end

# A function (`cache === nothing`) with its sub-caches as `children`, or one sub-cache.
struct Row
    f::Any
    cache::Union{Nothing, AbstractCache}
    label::String # the function, or the signature of the sub-cache
    kind::String
    bytes::Bool
    stats::STATS # summed over the children for a function
    trend::Trend
    children::Vector{Row}
end

hitrate(s) = (n = s.hits + s.misses; n == 0 ? NaN : s.hits / n)
activity(r::Row) = isempty(r.trend.rates) ? 0.0 : r.trend.rates[end]
fill_fraction(s, maxsize = s.maxsize) = maxsize == 0 ? 1.0 : s.currentsize / maxsize

# `f(::A, ::B; k::C)::V` from a cache's key and value types. The key is the tuple of positional
# arguments, followed by a `NamedTuple` of keywords when there are any (see `Cached._key`), so a
# trailing positional `NamedTuple` argument is shown as keywords too.
function signature(name::AbstractString, K::Type, V::Type)
    K isa DataType && K <: Tuple || return "$name[$K]::$V"
    args = collect(Any, fieldtypes(K))
    kws = ""
    if !isempty(args) && args[end] isa DataType && args[end] <: NamedTuple
        kw = pop!(args)
        kws = "; " * join(("$k::$T" for (k, T) in zip(fieldnames(kw), fieldtypes(kw))), ", ")
    end
    return string(name, "(", join(("::$T" for T in args), ", "), kws, ")::", V)
end

# Sort orders, by key on a `Row`; the last three are also the optional table columns.
const SORTS = (
    "Name" => r -> r.label,
    "Hit rate" => r -> (h = hitrate(r.stats); isnan(h) ? -1.0 : h),
    "Size" => r -> fill_fraction(r.stats),
    "Activity" => activity,
)

@kwdef mutable struct Dashboard <: Model
    interval::Float64 = 1.0
    filter::String = ""
    rows::Vector{Row} = Row[]                     # one per function, as read at the last refresh
    lines::Vector{Pair{Row, String}} = Pair{Row, String}[] # shown rows => their text
    trends::IdDict{Any, Trend} = IdDict{Any, Trend}() # by function or cache
    collapsed::IdDict{Any, Bool} = IdDict{Any, Bool}()
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

selected(m::Dashboard) = (i = m.selected; 1 <= i <= length(m.lines) ? first(m.lines[i]) : nothing)
_id(r::Row) = r.cache === nothing ? r.f : r.cache
_current(r::Row) = r.cache === nothing ? first(r.children).stats.maxsize : r.stats.maxsize

# --- refresh ---

function refresh!(m::Dashboard, now = time())
    elapsed = now - m.lastrefresh
    m.lastrefresh = now
    trends = IdDict{Any, Trend}()
    caches = IdDict{Any, Vector{Row}}()
    order = Any[]
    for (f, c) in cache_info()
        s = STATS(cache_stats(c))
        kind = c isa Cached.LRU ? "LRU" : c isa Cached.ClockCache ? "Clock" : string(nameof(typeof(c)))
        trend = trend!(trends, m.trends, c, s, elapsed)
        row = Row(f, c, signature(repr(f), keytype(c), valtype(c)), kind, c.by !== nothing, s, trend, Row[])
        haskey(caches, f) || push!(order, f)
        push!(get!(caches, f, Row[]), row)
    end
    m.rows = map(order) do f
        children = caches[f]
        s = reduce((a, b) -> STATS(map(+, a, b)), (c.stats for c in children))
        kind = allequal(c.kind for c in children) ? first(children).kind : "mixed"
        trend = trend!(trends, m.trends, f, s, elapsed)
        Row(f, nothing, repr(f), kind, first(children).bytes, s, trend, children)
    end
    m.trends = trends # drops the trends of caches that are gone
    return rebuild!(m)
end

function trend!(trends, old, id, s, elapsed)
    t = get(old, id, nothing)
    if t === nothing
        t = Trend(s.hits, s.misses, Float64[], NaN)
    else
        dh, dm = max(s.hits - t.hits, 0), max(s.misses - t.misses, 0)
        push!(t.rates, elapsed > 0 ? dh / elapsed : 0.0)
        length(t.rates) > HISTORY && popfirst!(t.rates)
        t.recent = dh + dm == 0 ? NaN : dh / (dh + dm)
        t.hits, t.misses = s.hits, s.misses
    end
    return trends[id] = t
end

# Filter, sort and flatten the tree into `lines`, keeping the selected row selected.
function rebuild!(m::Dashboard)
    current = selected(m)
    by = last(SORTS[m.sortcol])
    m.lines = empty(m.lines)
    for r in sort!(filter(r -> occursin(m.filter, r.label), m.rows); by, rev = m.reverse)
        if length(r.children) == 1 # shown inline, as its signature
            push!(m.lines, r => "  " * only(r.children).label)
        elseif get(m.collapsed, r.f, false)
            push!(m.lines, r => "▸ $(r.label) ($(length(r.children)) caches)")
        else
            push!(m.lines, r => "▾ $(r.label)")
            children = sort(r.children; by, rev = m.reverse)
            for (i, c) in enumerate(children)
                push!(m.lines, c => (i == length(children) ? "  └ " : "  ├ ") * chopprefix(c.label, r.label))
            end
        end
    end
    i = current === nothing ? nothing : findfirst(l -> _id(first(l)) === _id(current), m.lines)
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
    elseif key in (:left, :right) || (key == :char && c == ' ')
        fold!(m, r, key == :left ? true : key == :right ? false : nothing)
    elseif key == :enter
        m.pending = _current(r)
    elseif key == :char && c == 'e'
        r.cache === nothing ? empty_caches!(r.f) : empty!(r.cache)
        m.message = "emptied $(r.cache === nothing ? "all caches of " : "")$(r.label)"
        refresh!(m)
    end
    return nothing
end

# Collapse (`true`), expand (`false`) or toggle (`nothing`) the function of row `r`.
function fold!(m::Dashboard, r::Row, collapse)
    r.cache === nothing || collapse !== false || return m # → on a sub-cache does nothing
    parent = r.cache === nothing ? r : m.rows[findfirst(p -> p.f === r.f, m.rows)]
    length(parent.children) > 1 || return m
    m.collapsed[parent.f] = something(collapse, !get(m.collapsed, parent.f, false))
    m.selected = findfirst(l -> first(l) === parent, m.lines) # select the function
    return rebuild!(m)
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

# A sub-cache is resized on its own; a function gets a limit for its current and future caches,
# in its current measure (`set_cache_size!` would discard the caches if `by` changed).
function resize_row!(m::Dashboard, r::Row, n::Int)
    if r.cache === nothing
        set_cache_size!(r.f, n; by = first(r.children).cache.by)
        m.message = "set the limit of $(r.label) to $(_short(n, r.bytes))"
    else
        resize!(r.cache; maxsize = n)
        m.message = "resized $(r.label) to $(_short(n, r.bytes))"
    end
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
    ncaches = sum(r -> length(r.children), m.rows; init = 0)
    filt = isempty(m.filter) ? "" : " · filter \"$(m.filter)\""
    title = " $ncaches caches in $(length(m.rows)) functions, $entries entries$filt"
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
    ("Activity", 8, (buf, x, y, r, m) -> render(Sparkline(r.trend.rates; style = tstyle(:accent)), Rect(x, y, 8, 1), buf)),
)
const MINNAME = 20 # width of the name column below which columns are dropped

function render_table(m::Dashboard, area::Rect, buf)
    k = 0
    while k < length(COLUMNS) && area.width - 1 - sum(c -> c[2] + 1, COLUMNS[1:(k + 1)]) >= MINNAME
        k += 1
    end
    columns = COLUMNS[1:k]
    namewidth = area.width - 1 - sum(c -> c[2] + 1, columns; init = 0)

    sorted, arrow = first(SORTS[m.sortcol]), m.reverse ? " ▼" : " ▲"
    x = area.x + 1
    for (name, w, _) in (("Name", namewidth, nothing), columns...)
        set_string!(buf, x, area.y, name == sorted ? name * arrow : name, tstyle(:title, bold = true); max_x = x + w - 1)
        x += w + 1
    end

    height = area.height - 1
    m.offset = clamp(m.offset, max(m.selected - height, 0), max(m.selected - 1, 0))
    for (i, (r, label)) in enumerate(m.lines[(m.offset + 1):min(end, m.offset + height)])
        y = area.y + i
        issel = m.offset + i == m.selected
        style = issel ? tstyle(:accent, bold = true) : tstyle(:text; bold = r.cache === nothing && length(r.children) > 1)
        issel && set_char!(buf, area.x, y, '▌', style)
        set_string!(buf, area.x + 1, y, _truncate(label, namewidth), style)
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
    h = hitrate(r.stats)
    style = isnan(h) ? tstyle(:text_dim) : tstyle(h < 0.5 ? :error : h < 0.8 ? :warning : :success)
    bar!(buf, x, y, 8, isnan(h) ? 0.0 : h, style)
    set_string!(buf, x + 9, y, isnan(h) ? "   -" : lpad("$(round(Int, 100h))%", 4), style)
    return
end

# The fill against the limit, or against the pending limit while resizing this row.
function draw_size(buf, x, y, r::Row, m::Dashboard)
    resizing = m.pending !== nothing && selected(m) === r
    # a function's limit applies to each of its caches
    maxsize = resizing ? m.pending * max(length(r.children), 1) : r.stats.maxsize
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
    caches = length(r.children) > 1 ? "$(length(r.children)) caches · " : ""
    lines = (
        "$caches$(r.kind) · $size · $(s.hits) hits · $(s.misses) misses",
        "hit rate $(_percent(hitrate(s))), recent $(_percent(t.recent)) · $(round(activity(r); digits = 1)) hits/s",
    )
    for (i, line) in enumerate(lines)
        set_string!(buf, inner.x, inner.y + i - 1, line, tstyle(:text); max_x = right(inner))
    end
    render(Sparkline(t.rates; style = tstyle(:accent)), Rect(inner.x, inner.y + 2, inner.width, 1), buf)
    return
end

const KEYS = "↑↓ select  ←→ fold  ⏎ resize  e empty  s sort  r reverse  / filter  q quit"
const RESIZEKEYS = "←→ ½ ×2  [ ] ±10%  ⏎ apply  Esc cancel"

function render_status(m::Dashboard, area::Rect, buf)
    r = selected(m)
    if m.input !== nothing
        render(m.input, area, buf)
    elseif m.pending !== nothing && r !== nothing
        change = " $(_short(_current(r), r.bytes)) → $(_short(m.pending, r.bytes)) "
        what = r.cache === nothing ? " each cache of $(r.label) " : " $(r.label) "
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

# At most `w` characters, cutting the middle so that both ends of a signature stay visible.
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
