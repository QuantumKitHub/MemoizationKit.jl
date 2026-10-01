"""
    cache_info() -> Vector{Pair{Any, AbstractCache}}
    cache_info(f) -> Vector{Pair{Any, AbstractCache}}

The global caches, or the global caches of `f`, as `f => cache` pairs with the oldest cache of
each function first. The caches are live: they show their size and hit statistics, and can be
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

Set the size limit of every global cache of `f`, current and future, overriding the
preferences (see the configuration docs). Without `by`, `maxsize`
counts entries; otherwise it bounds the sum of `by(value)` over the entries of each cache.
Changing `by` discards the existing caches of `f`.
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
    set_max_subcaches!(f, n::Integer)

Limit the number of global caches of `f`, one per key and value type. When a new key type
would exceed the limit, the oldest cache of `f` is dropped.
"""
function set_max_subcaches!(f, n::Integer)
    n >= 1 || throw(ArgumentError("a function needs at least one cache"))
    @lock REGISTRY.lock begin
        fc = _functioncaches!(f)
        fc.maxsubcaches = n
        if length(fc.caches) > n
            deleteat!(fc.caches, 1:(length(fc.caches) - n))
            _publish!()
        end
    end
    return nothing
end
