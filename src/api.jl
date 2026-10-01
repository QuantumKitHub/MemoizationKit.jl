"""
    cache_info() -> Vector{Pair{Any, AbstractCache}}
    cache_info(f) -> Vector{Pair{Any, AbstractCache}}

The global caches, or the global caches of `f`, as `f => cache` pairs. A function has one
cache, holding all its signatures (or one per container type, if its [`CacheStyle`](@ref)
selects several). The caches are live: they show their size and hit statistics, and can be
inspected, emptied or resized directly. Task-local caches are not included.
"""
cache_info() = @lock REGISTRY.lock Pair{Any, AbstractCache}[f => c for (f, fc) in REGISTRY.functions for c in fc.caches]
cache_info(f) = @lock REGISTRY.lock Pair{Any, AbstractCache}[f => c for c in _caches(f)]

_caches(f) = (fc = get(REGISTRY.functions, f, nothing); fc === nothing ? AbstractCache[] : fc.caches)

"""
    empty_caches!()
    empty_caches!(f)

Empty every global cache, or the global caches of `f`. Statistics are kept.
"""
empty_caches!() = (@lock REGISTRY.lock foreach(fc -> foreach(empty!, fc.caches), values(REGISTRY.functions)); nothing)
empty_caches!(f) = (@lock REGISTRY.lock foreach(empty!, _caches(f)); nothing)

"""
    set_cache_size!(f, maxsize::Integer; by = nothing)

Set the size limit of the global cache of `f`, overriding the preferences (see the
configuration docs). The limit applies to the function as a whole, all signatures together.
Without `by`, `maxsize` counts entries; otherwise it bounds the sum of `by(value)` over the
entries, e.g. with `by = Cached.cachesize` for bytes. Changing `by` discards the cache of `f`.
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
live hit rates and sizes, from which caches can be emptied or resized. The
statistics are re-read every `interval` seconds, and only functions whose name contains
`filter` are shown.

The dashboard is a package extension: load [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)
first, with `using Tachikoma`. See [Dashboard](@ref) for the keybindings.
"""
function cache_dashboard(; kwargs...)
    ext = Base.get_extension(@__MODULE__, :CachedTachikomaExt)
    ext === nothing && error("cache_dashboard requires Tachikoma.jl; run `using Tachikoma` first")
    return Base.invokelatest(ext.dashboard; kwargs...)
end
