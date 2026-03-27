# -------------------------------------------------------------------------
# Preferences and defaults
# -------------------------------------------------------------------------

# Loaded from LocalPreferences.toml at module load time.
const PREF_GLOBALCACHE_BYTESIZE::Bool = parse(Bool, @load_preference("globalcache_bytesize", "true"))

"""
    DEFAULT_GLOBALCACHE_SIZE

Default size for global LRU caches created by `@cached`.
64 GiB if byte-based sizing is active (the default), or 10 000 entries otherwise.
Configured via `LocalPreferences.toml`; see [`set_default_cache_bytesize!`](@ref).
"""
const DEFAULT_GLOBALCACHE_SIZE::Int = parse(
    Int, @load_preference("globalcache_size", string(PREF_GLOBALCACHE_BYTESIZE ? 2^36 : 10^4))
)

"""
    GLOBALCACHE_SIZE_FUNCTION

A `Ref{Function}` holding the default size measurer used by byte-based global LRU caches.
Initially `Base.summarysize`. Change it before loading packages that use `@cached` to
affect newly created caches, or use [`set_cache_bytesize!`](@ref) to update individual
caches after the fact.

```julia
GLOBALCACHE_SIZE_FUNCTION[] = sizeof  # use cheaper estimator globally
```
"""
const GLOBALCACHE_SIZE_FUNCTION = Ref{Function}(Base.summarysize)

# Sentinel `by` function for count-based LRU caches.
# lru.by === _COUNT_BY  ⟺  cache is count-based.
const _COUNT_BY = Returns(1)
