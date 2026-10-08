"""
    cache_info() -> Vector{Pair{Any, AbstractCache}}
    cache_info(f) -> Vector{Pair{Any, AbstractCache}}
    cache_info(m::Module) -> Vector{Pair{Any, AbstractCache}}

The global caches, those of `f`, or those of the functions owned by the module `m` or its
submodules, as `f => cache` pairs. A function has one cache, holding all its signatures (or
one per container type, if its [`CacheStyle`](@ref) selects several), and is owned by the
module that defines it, `parentmodule(typeof(f))`, wherever its `@cached` methods are written.
The caches are live: they show their size and hit statistics, and can be inspected, emptied or
resized directly. Task-local caches are not included.
"""
cache_info() = _cache_info(Returns(true))
cache_info(f) = _cache_info(g -> g === f)
cache_info(m::Module) = _cache_info(g -> _within(parentmodule(typeof(g)), m))

_cache_info(select) = @lock REGISTRY.lock Pair{Any, AbstractCache}[f => c for (f, fc) in REGISTRY.functions if select(f) for c in fc.caches]
_within(n::Module, m::Module) = n === m || ((p = parentmodule(n)) !== n && _within(p, m))

"""
    empty_caches!()
    empty_caches!(f)
    empty_caches!(m::Module)

Empty every global cache, those of `f`, or those of the functions owned by the module `m` or
its submodules (see [`cache_info`](@ref)). Statistics are kept.
"""
empty_caches!() = _empty!(cache_info())
empty_caches!(f) = _empty!(cache_info(f))
empty_caches!(m::Module) = _empty!(cache_info(m))

_empty!(caches) = (foreach(empty! ∘ last, caches); nothing)

"""
    set_cache_size!(f, maxsize::Integer; by = nothing)

Set the size limit of the global cache of `f`, overriding the preferences (see the
configuration docs). The limit applies to the function as a whole, all signatures together.
Without `by`, `maxsize` counts entries; otherwise it bounds the sum of `by(value)` over the
entries, e.g. with `by = MemoizationKit.cachesize` for bytes. Changing `by` discards the cache of `f`.
"""
function set_cache_size!(f, maxsize::Integer; by = nothing)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    @lock REGISTRY.lock begin
        fc = _functioncaches!(f)
        fc.maxsize = maxsize
        if by === fc.by
            foreach(c -> resize!(c; maxsize), fc.caches)
        else
            fc.by = by
            empty!(fc.caches)
            _publish!()
        end
    end
    return nothing
end

"""
    cache_dashboard(; interval = 1.0, filter = "")

Open an interactive terminal dashboard of the global caches: one row per function, with
live hit rates and sizes, from which caches can be emptied or resized. A second tab lists the
disk caches in use (see the disk caching docs), with their entries, size and hit rate. The
statistics are re-read every `interval` seconds, and only functions whose name contains
`filter` are shown.

The dashboard is a package extension: load [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)
first, with `using Tachikoma`. See [Dashboard](@ref) for the keybindings.
"""
function cache_dashboard end

"""
    enable_cache_timers!(M::Module, timer::TimerOutput = TimerOutputs.get_defaulttimer())

Record the time spent in the cached functions owned by the package `M`, or any of its
submodules, in `timer`: a section per function and phase, the lookup (hit or miss) with the
computation of a miss nested in it, labelled by [`MemoizationKit.instrument_label`](@ref). This
includes methods of these functions cached in other packages. Modules outside packages, such
as those defined in the REPL, count separately. Enabling `M` again replaces its timer;
[`disable_cache_timers!`](@ref) stops.

Enabling and disabling define and delete a method of an internal hook, so they recompile the callers of the functions of `M`, and only take effect for code that starts
afterwards (from the next top-level statement on, or through `invokelatest`). They cannot be
used during precompilation.

This is a package extension: load [TimerOutputs.jl](https://github.com/KristofferC/TimerOutputs.jl)
first, with `using TimerOutputs`. See [Timing](@ref) for the details.
"""
function enable_cache_timers! end

"""
    disable_cache_timers!(M::Module)

Stop timing the cached functions owned by `M`, started by [`enable_cache_timers!`](@ref).
Their calls recompile without the timers, at no cost again.
"""
function disable_cache_timers! end

# Functions whose methods come from a package extension, with the package to load.
const EXTENSIONS = (
    cache_dashboard => (:MemoizationKitTachikomaExt, "Tachikoma"),
    enable_cache_timers! => (:MemoizationKitTimerOutputsExt, "TimerOutputs"),
    disable_cache_timers! => (:MemoizationKitTimerOutputsExt, "TimerOutputs"),
    disk_lookup => (:MemoizationKitSQLiteExt, "SQLite"),
    disk_cache_info => (:MemoizationKitSQLiteExt, "SQLite"),
    disk_cache_stats => (:MemoizationKitSQLiteExt, "SQLite"),
    empty_disk_caches! => (:MemoizationKitSQLiteExt, "SQLite"),
    export_disk_cache => (:MemoizationKitSQLiteExt, "SQLite"),
)

# Without the extension these functions have no methods; say how to get them. Calls with
# keywords fail on `Core.kwcall`, with the function as the second argument.
function _extension_hint(io, exc, argtypes, kwargs)
    f = exc.f === Core.kwcall && length(exc.args) >= 2 ? exc.args[2] : exc.f
    for (g, (ext, pkg)) in EXTENSIONS
        f === g && Base.get_extension(@__MODULE__, ext) === nothing &&
            print(io, "\n`$(g === disk_lookup ? "DiskCache" : nameof(g))` needs $pkg.jl: run `using $pkg` first.")
    end
    return nothing
end
