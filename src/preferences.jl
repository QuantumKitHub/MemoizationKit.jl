# Default settings, configurable through Preferences.jl (see `docs/src/configuration.md`).
#
# Settings are resolved once per function, when its first cache is created:
#     runtime calls (`set_cache_size!`, ...) > [<Package>.Cached.<function>] > [<Package>.Cached]
#         > [Cached] > built-in defaults
# where <Package> is the package that owns the function (`parentmodule(typeof(f))`).
# The default container is a compile-time preference of Cached only, since it selects the
# `CacheStyle` and so must be a constant.

const BUILTIN_SETTINGS = (; maxsize = 10_000, measure = "count", maxsubcaches = 100)
const SETTING_KEYS = map(string, keys(BUILTIN_SETTINGS))
const MEASURES = Dict{String, Any}("count" => nothing, "bytes" => Base.summarysize)

const DEFAULT_CONTAINER = let name = @load_preference("container", "ClockCache")
    containers = Dict("ClockCache" => ClockCache, "LRU" => LRU)
    haskey(containers, name) ||
        error("Cached: invalid preference `container = $(repr(name))`; use \"ClockCache\" or \"LRU\"")
    containers[name]
end

# Resolve settings from the preference sections, most general first. `package` is the
# `[<Package>.Cached]` table (or `nothing`), whose sub-tables are per-function sections.
function _resolve_settings(fname::AbstractString, cached::AbstractDict, package)
    settings = Dict{String, Any}(string(k) => v for (k, v) in pairs(BUILTIN_SETTINGS))
    _merge_settings!(settings, cached, "[Cached]")
    if package isa AbstractDict
        _merge_settings!(settings, package, "[<package>.Cached]")
        section = get(package, fname, nothing)
        section isa AbstractDict && _merge_settings!(settings, section, "[<package>.Cached.$fname]")
    end
    return (;
        maxsize = settings["maxsize"]::Integer,
        by = MEASURES[settings["measure"]],
        maxsubcaches = settings["maxsubcaches"]::Integer,
    )
end

function _merge_settings!(settings, section::AbstractDict, where)
    for (k, v) in section
        v isa AbstractDict && continue # per-function section
        if !(k in SETTING_KEYS)
            @warn "Cached: ignoring unknown preference `$k` in $where"
        elseif k == "measure" ? !haskey(MEASURES, v) :
                !(v isa Integer && !(v isa Bool) && v >= (k == "maxsubcaches" ? 1 : 0))
            @warn "Cached: ignoring invalid preference `$k = $(repr(v))` in $where"
        else
            settings[k] = v
        end
    end
    return settings
end

_cached_section() = Dict{String, Any}(
    k => load_preference(@__MODULE__, k) for k in SETTING_KEYS if has_preference(@__MODULE__, k)
)

function _package_section(f)
    mod = Base.moduleroot(parentmodule(typeof(f)))
    Base.PkgId(mod).uuid === nothing && return nothing # not a package, e.g. Main
    return load_preference(mod, "Cached", nothing)
end

_fname(f) = string(f isa Function ? nameof(f) : nameof(typeof(f)))

function FunctionCaches(f)
    s = _resolve_settings(_fname(f), _cached_section(), _package_section(f))
    return FunctionCaches(s.maxsize, s.by, s.maxsubcaches, AbstractCache[])
end

# The registry entry of `f`, created with its preferences on first use. Call with
# `REGISTRY.lock` held.
_functioncaches!(f) = get!(() -> FunctionCaches(f), REGISTRY.functions, f)
