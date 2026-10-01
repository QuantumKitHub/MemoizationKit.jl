# Registry of the global caches.
#
# Lookups read an immutable snapshot of `table` without locking; creating a cache copies the
# snapshot under `lock`. New caches are rare (once per function and key/value type), so the
# copy is cheap compared to taking a lock on every call.

const DEFAULT_MAXSIZE = 10_000
const DEFAULT_MAXSUBCACHES = 100

# Per-function limits and the function's caches, oldest first.
mutable struct FunctionCaches
    maxsize::Int
    by::Any
    maxsubcaches::Int
    const caches::Vector{AbstractCache}
end
FunctionCaches() = FunctionCaches(DEFAULT_MAXSIZE, nothing, DEFAULT_MAXSUBCACHES, AbstractCache[])

mutable struct Registry
    @atomic table::IdDict{Any, Any} # _tablekey(f, C{K,V}) => C{K,V}; never mutated once published
    const functions::IdDict{Any, FunctionCaches}
    const lock::ReentrantLock
end

const REGISTRY = Registry(IdDict{Any, Any}(), IdDict{Any, FunctionCaches}(), ReentrantLock())

# For singleton functions the key is a type, which is a compile-time constant with a cached hash.
# Callable objects with fields are distinguished by value.
_tablekey(f::F, ::Type{T}) where {F, T} = Base.issingletontype(F) ? Tuple{F, T} : (f, T)

function globalcache(f, ::Type{T}) where {T}
    c = get((@atomic :acquire REGISTRY.table), _tablekey(f, T), nothing)
    return c === nothing ? _newglobalcache!(f, T) : c
end

@noinline function _newglobalcache!(f, ::Type{T}) where {T}
    return @lock REGISTRY.lock begin
        c = get((@atomic :acquire REGISTRY.table), _tablekey(f, T), nothing)
        c === nothing || return c
        fc = get!(FunctionCaches, REGISTRY.functions, f)
        c = T(; maxsize = fc.maxsize, by = fc.by)
        push!(fc.caches, c)
        length(fc.caches) > fc.maxsubcaches && popfirst!(fc.caches)
        _publish!()
        c
    end
end

# Rebuild the lookup table from the per-function cache lists. Call with `REGISTRY.lock` held.
function _publish!()
    table = IdDict{Any, Any}()
    for (f, fc) in REGISTRY.functions, c in fc.caches
        table[_tablekey(f, typeof(c))] = c
    end
    @atomic :release REGISTRY.table = table
    return nothing
end
