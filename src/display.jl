# -------------------------------------------------------------------------
# Cache visualisation
# -------------------------------------------------------------------------

function _format_bytes(n::Integer)
    n < 1024   && return string(n, " B")
    n < 1024^2 && return @sprintf("%.1f KB", n / 1024)
    n < 1024^3 && return @sprintf("%.1f MB", n / 1024^2)
    return @sprintf("%.1f GB", n / 1024^3)
end

function _table_hline(io, widths, left, mid, right)
    print(io, left)
    for (i, w) in enumerate(widths)
        print(io, "─"^(w + 2))
        print(io, i < length(widths) ? mid : right)
    end
    println(io)
end

function _table_row(io, cells, widths)
    print(io, "│")
    for (cell, w) in zip(cells, widths)
        print(io, " ", rpad(cell, w), " │")
    end
    println(io)
end

"""
    global_cache_info(io::IO = stdout)

Display a summary table of all registered global LRU caches, including hit/miss
statistics, fill level, and memory usage.

For count-based caches the Fill column shows `current/max` entries and Memory shows
estimated bytes. For byte-based caches Fill shows entry count and Memory shows
`current/max` as human-readable byte counts.
"""
function global_cache_info(io::IO = stdout)
    if isempty(PER_SIG_CACHES)
        println(io, "No global caches registered.")
        return
    end

    header = ("Signature", "Hits", "Misses", "Hit rate", "Fill", "Memory")

    sorted_pairs = sort!(collect(PER_SIG_CACHES); by = p -> p[1])

    rows = map(sorted_pairs) do (sig_key, lru)
        info    = LRUCache.cache_info(lru)
        hits    = info.hits
        misses  = info.misses
        total   = hits + misses
        hitrate = total == 0 ? "N/A" : @sprintf("%.1f%%", 100.0 * hits / total)
        fill, mem = if _is_bytesize(lru)
            string(length(lru)),
            "$(_format_bytes(info.currentsize)) / $(_format_bytes(info.maxsize))"
        else
            "$(info.currentsize)/$(info.maxsize)",
            _format_bytes(Base.summarysize(lru))
        end
        (sig_key, string(hits), string(misses), hitrate, fill, mem)
    end

    widths = [length(h) for h in header]
    for row in rows
        for i in eachindex(widths)
            widths[i] = max(widths[i], length(row[i]))
        end
    end

    n = length(PER_SIG_CACHES)
    println(io, "Cache Usage Summary (", n, " cache", n == 1 ? "" : "s", ")")
    _table_hline(io, widths, '┌', '┬', '┐')
    _table_row(io, header, widths)
    _table_hline(io, widths, '├', '┼', '┤')
    for row in rows
        _table_row(io, row, widths)
    end
    _table_hline(io, widths, '└', '┴', '┘')
    return
end
