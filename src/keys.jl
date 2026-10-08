"""
    Hashed(value, hashf = Base.hash, eqf = Base.isequal)

Wrap `value` with custom hashing and equality for use as a dictionary or cache key.
`hashf(value, seed::UInt)` computes its hash; `eqf(a, b)` compares the wrapped values.
Retrieve the value with `parent`. Both functions may also be callable structs.

Two wrappers compare equal only when their hash and equality callables are identical
(`===`) and `eqf` considers their values equal. The equality must be an equivalence
relation, and equivalent values must have equal hashes for every seed. Values and
callable state that affect hashing or equality must remain unchanged while stored.

Use [`MemoizationKit.cachekey`](@ref) to wrap inputs without changing a cached function's signature.
Custom equality affects RAM caching; disk caching compares serialized key bytes.
"""
struct Hashed{T, H, E}
    val::T
    hashf::H
    eqf::E
end

Hashed(val) = Hashed(val, Base.hash, Base.isequal)
Hashed(val, hashf) = Hashed(val, hashf, Base.isequal)

Base.parent(h::Hashed) = h.val
Base.hash(h::Hashed, seed::UInt) = h.hashf(parent(h), seed)
Base.isequal(::Hashed, ::Hashed) = false
Base.isequal(a::Hashed{<:Any, H, E}, b::Hashed{<:Any, H, E}) where {H, E} =
    a.hashf === b.hashf && a.eqf === b.eqf && a.eqf(parent(a), parent(b))
Base.:(==)(a::Hashed, b::Hashed) = isequal(a, b)

"""
    MemoizationKit.cachekey(f, args...; kwargs...)

Return the key used to memoize a call of a [`@cached`](@ref) function. By default it is
the positional argument tuple, followed by the keyword `NamedTuple` when nonempty.
Specialize this function to map equivalent inputs to a shared key:

```julia
MemoizationKit.cachekey(::typeof(f), x; scale = 1) = (length(x), scale)
MemoizationKit.cachekey(::typeof(g), x) = (Hashed(x, customhash, customequal),)
```

The implementation, return-type inference, and cache strategies still receive the original
arguments. Custom keys can merge calls to different methods or argument types; all merged
calls must admit the same cached result, including its return type. MemoizationKit's RAM containers
distinguish key types, so keys intended to share an entry must also have the same type.
The key must remain stable while cached. [`uncached`](@ref) bypasses this hook.

RAM caches use hashing and equality; disk caches compare serialized bytes, so a canonical
representation is needed to share disk entries between different inputs. After changing
the mapping, empty existing RAM caches and update [`MemoizationKit.diskversion`](@ref) if using disk.
"""
cachekey(f, args...; kwargs...) = _key(args, NamedTuple(kwargs))

_key(args::Tuple, ::NamedTuple{()}) = args
_key(args::Tuple, kw::NamedTuple) = (args..., kw)

@inline _callkey(f::F, args::Tuple, kw::NamedTuple) where {F} = cachekey(f, args...; kw...)
