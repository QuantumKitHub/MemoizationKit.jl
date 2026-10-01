"""
    CacheInfo

Summary of one global cache, as returned by [`cache_info`](@ref): the function `f`, the
container type `C{K, V}`, and its `hits`, `misses`, `length`, `currentsize` and `maxsize`.
"""
struct CacheInfo
    f::Any
    type::Type
    hits::Int
    misses::Int
    length::Int
    currentsize::Int
    maxsize::Int
end

function Base.show(io::IO, ::MIME"text/plain", info::CacheInfo)
    total = info.hits + info.misses
    rate = total == 0 ? "-" : string(round(100 * info.hits / total; digits = 1), "%")
    print(
        io, info.f isa Function ? nameof(info.f) : info.f, " :: ", info.type, ": ", info.length, " entries, size ",
        info.currentsize, "/", info.maxsize, ", ", info.hits, " hits, ", info.misses,
        " misses (", rate, ")"
    )
    return nothing
end

"""
    cache_info() -> Vector{CacheInfo}
    cache_info(f) -> Vector{CacheInfo}

Statistics of every global cache, or of the global caches of `f`. Task-local caches are not
included.
"""
cache_info() = @lock REGISTRY.lock reduce(vcat, (_info(f, fc) for (f, fc) in REGISTRY.functions); init = CacheInfo[])
cache_info(f) = @lock REGISTRY.lock _info(f, get(FunctionCaches, REGISTRY.functions, f))

function _info(f, fc::FunctionCaches)
    return map(fc.caches) do c
        s = cache_stats(c)
        CacheInfo(f, typeof(c), s.hits, s.misses, s.length, s.currentsize, s.maxsize)
    end
end

"""
    empty_caches!()
    empty_caches!(f)

Empty every global cache, or the global caches of `f`. Statistics are kept.
"""
empty_caches!() = (@lock REGISTRY.lock foreach(fc -> foreach(empty!, fc.caches), values(REGISTRY.functions)); nothing)
empty_caches!(f) = (@lock REGISTRY.lock foreach(empty!, get(FunctionCaches, REGISTRY.functions, f).caches); nothing)

"""
    set_cache_size!(f, maxsize::Integer; by = nothing)

Set the size limit of every global cache of `f`, current and future. Without `by`, `maxsize`
counts entries; otherwise it bounds the sum of `by(value)` over the entries of each cache.
Changing `by` discards the existing caches of `f`.
"""
function set_cache_size!(f, maxsize::Integer; by = nothing)
    maxsize >= 0 || throw(ArgumentError("maxsize must be non-negative"))
    @lock REGISTRY.lock begin
        fc = get!(FunctionCaches, REGISTRY.functions, f)
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
        fc = get!(FunctionCaches, REGISTRY.functions, f)
        fc.maxsubcaches = n
        if length(fc.caches) > n
            deleteat!(fc.caches, 1:(length(fc.caches) - n))
            _publish!()
        end
    end
    return nothing
end
