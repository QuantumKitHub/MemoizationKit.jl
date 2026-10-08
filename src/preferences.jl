# Default settings, configurable through Preferences.jl (see `docs/src/configuration.md`).
#
# Settings are resolved once per function, when its first cache is created:
#     runtime calls (`set_cache_size!`, ...) > [<Package>.MemoizationKit.<function>] > [<Package>.MemoizationKit]
#         > [MemoizationKit] > built-in defaults
# where <Package> is the package that owns the function (`parentmodule(typeof(f))`).
# The default container is a compile-time preference of MemoizationKit only, since it selects the
# `CacheStyle` and so must be a constant.

const BUILTIN_SETTINGS = (; maxsize = 10_000, measure = "count", disk = true, disk_path = "")
const SETTING_KEYS = map(string, keys(BUILTIN_SETTINGS))
"""
    MemoizationKit.cachesize(x) -> Integer

Size in bytes of a cached value `x`, used by caches whose `measure` is `"bytes"`. Defaults to
`Base.summarysize(x)`. Overload it for your own types when that is slow (it traverses the
whole object) or inaccurate (memory shared between values is counted for each of them):

```julia
MemoizationKit.cachesize(t::MyTensor) = sizeof(t.data)
```
"""
cachesize(x) = Base.summarysize(x)

const MEASURES = Dict{String, Any}("count" => nothing, "bytes" => cachesize)

const DEFAULT_CONTAINER = let name = @load_preference("container", "ClockCache")
    containers = Dict("ClockCache" => ClockCache, "LRU" => LRU)
    haskey(containers, name) ||
        error("MemoizationKit: invalid preference `container = $(repr(name))`; use \"ClockCache\" or \"LRU\"")
    containers[name]
end

# Resolve settings from the preference sections, most general first. `package` is the
# `[<Package>.MemoizationKit]` table (or `nothing`), whose sub-tables are per-function sections.
function _resolve_settings(fname::AbstractString, cached::AbstractDict, package)
    settings = Dict{String, Any}(string(k) => v for (k, v) in pairs(BUILTIN_SETTINGS))
    _merge_settings!(settings, cached, "[MemoizationKit]")
    if package isa AbstractDict
        _merge_settings!(settings, package, "[<package>.MemoizationKit]")
        section = get(package, fname, nothing)
        section isa AbstractDict && _merge_settings!(settings, section, "[<package>.MemoizationKit.$fname]")
    end
    return (;
        maxsize = settings["maxsize"]::Integer,
        by = MEASURES[settings["measure"]],
        disk = settings["disk"]::Bool,
        disk_path = String(settings["disk_path"]),
    )
end

function _merge_settings!(settings, section::AbstractDict, where)
    for (k, v) in section
        v isa AbstractDict && continue # per-function section
        if !(k in SETTING_KEYS)
            @warn "MemoizationKit: ignoring unknown preference `$k` in $where"
        elseif !_isvalid(k, v)
            @warn "MemoizationKit: ignoring invalid preference `$k = $(repr(v))` in $where"
        else
            settings[k] = v
        end
    end
    return settings
end

_isvalid(k, v) = k == "measure" ? haskey(MEASURES, v) :
    k == "container" ? v in ("ClockCache", "LRU") :
    k == "disk" ? v isa Bool : k == "disk_path" ? v isa AbstractString :
    v isa Integer && !(v isa Bool) && v >= 0

_cached_section() = Dict{String, Any}(
    k => load_preference(@__MODULE__, k) for k in SETTING_KEYS if has_preference(@__MODULE__, k)
)

_owner(f) = Base.moduleroot(parentmodule(typeof(f)))
_ispackage(mod::Module) = Base.PkgId(mod).uuid !== nothing # not e.g. Main

function _package_section(f)
    mod = _owner(f)
    return _ispackage(mod) ? load_preference(mod, "MemoizationKit", nothing) : nothing
end

_fname(f) = string(f isa Function ? nameof(f) : nameof(typeof(f)))

function FunctionCaches(f)
    s = _resolve_settings(_fname(f), _cached_section(), _package_section(f))
    return FunctionCaches(s.maxsize, s.by, AbstractCache[])
end

# The registry entry of `f`, created with its preferences on first use. Call with
# `REGISTRY.lock` held.
_functioncaches!(f) = get!(() -> FunctionCaches(f), REGISTRY.functions, f)

"""
    set_cache_preferences!(; settings...)
    set_cache_preferences!(package::Module; settings...)
    set_cache_preferences!(f; settings...)

Store default cache settings in `LocalPreferences.toml`: globally (section `[MemoizationKit]`), for the
functions of `package` (`[<package>.MemoizationKit]`), or for the function `f` (`[<owner>.MemoizationKit.<f>]`,
where `<owner>` is the package that defines `f`). Settings are `maxsize`, `measure`
(`"count"` or `"bytes"`), `disk` and `disk_path` (see the disk caching docs), and, globally only, `container` (`"ClockCache"` or `"LRU"`). A value of `nothing` removes the setting.

Settings apply to functions whose first cache is created afterwards, so in practice after a
restart; changing `container` recompiles MemoizationKit. See the configuration docs for how settings
combine.

```julia
set_cache_preferences!(; maxsize = 100_000)
set_cache_preferences!(MyPackage; measure = "bytes", maxsize = 2^30)
set_cache_preferences!(MyPackage.expensive; maxsize = 50_000)
```
"""
set_cache_preferences!(; settings...) = set_cache_preferences!(@__MODULE__; settings...)

function set_cache_preferences!(mod::Module; settings...)
    mod = Base.moduleroot(mod)
    _check_settings(settings; global_ = mod === @__MODULE__)
    if mod === @__MODULE__
        for (k, v) in settings
            v === nothing ? delete_preferences!(mod, string(k); force = true) :
                set_preferences!(mod, string(k) => v; force = true)
        end
    else
        _ispackage(mod) || throw(ArgumentError("$mod is not a package"))
        _update_section!(section -> _apply!(section, settings), mod)
    end
    return nothing
end

function set_cache_preferences!(f; settings...)
    _check_settings(settings; global_ = false)
    mod = _owner(f)
    _ispackage(mod) || throw(ArgumentError("$f is not defined in a package"))
    _update_section!(mod) do section
        fsection = get!(Dict{String, Any}, section, _fname(f))
        _apply!(fsection, settings)
        isempty(fsection) && delete!(section, _fname(f))
    end
    return nothing
end

function _check_settings(settings; global_)
    for (k, v) in settings
        k = string(k)
        k in SETTING_KEYS || (global_ && k == "container") ||
            throw(ArgumentError("unknown cache setting `$k`" * (k == "container" ? " (only global)" : "")))
        v === nothing || _isvalid(k, v) || throw(ArgumentError("invalid cache setting `$k = $(repr(v))`"))
    end
    return nothing
end

_apply!(section, settings) = foreach(((k, v),) -> v === nothing ? delete!(section, string(k)) : (section[string(k)] = v), settings)

# Read-modify-write the `[<mod>.MemoizationKit]` table. It is deleted first, since `set_preferences!`
# merges tables and would otherwise keep removed keys.
function _update_section!(update!, mod::Module)
    section = deepcopy(load_preference(mod, "MemoizationKit", Dict{String, Any}()))
    update!(section)
    delete_preferences!(mod, "MemoizationKit"; force = true)
    isempty(section) || set_preferences!(mod, "MemoizationKit" => section; force = true)
    return nothing
end
