# -------------------------------------------------------------------------
# Cache registry
# -------------------------------------------------------------------------

"""
    PER_SIG_CACHES

`Dict{String, Any}` mapping each cached signature string (e.g. `"f(::Int, ::Float64)"`)
to its per-signature LRU cache object. All caches registered via [`@cached`](@ref) or
[`@cached_direct`](@ref) appear here and can be inspected with [`global_cache_info`](@ref).
"""
const PER_SIG_CACHES = Dict{String, Any}()

# Secondary index: function object → list of registered signature keys.
# Enables function-level APIs like set_cache_size!(f, n).
const _FUNC_TO_SIG_KEYS = IdDict{Function, Vector{String}}()

# -------------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------------

# Returns a new LRU{Any,Any} configured from module-load-time preferences.
function _make_global_lru()
    if PREF_GLOBALCACHE_BYTESIZE
        return LRU{Any,Any}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = GLOBALCACHE_SIZE_FUNCTION[])
    else
        return LRU{Any,Any}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = _COUNT_BY)
    end
end

# Returns a new typed LRU{K,V} configured from module-load-time preferences.
function _make_typed_global_lru(::Type{K}, ::Type{V}) where {K,V}
    if PREF_GLOBALCACHE_BYTESIZE
        return LRU{K,V}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = GLOBALCACHE_SIZE_FUNCTION[])
    else
        return LRU{K,V}(; maxsize = DEFAULT_GLOBALCACHE_SIZE, by = _COUNT_BY)
    end
end

# True if the cache measures size in bytes rather than entry count.
_is_bytesize(lru::LRU) = lru.by !== _COUNT_BY

# Returns the task_local_storage key for function f's task-local cache.
_tasklocal_key(f::Function) = Symbol(:_tasklocal_, parentmodule(f), :_, nameof(f), :_cache)

# Register sig_key → lru and f → [sig_keys] in the registries.
# Errors if sig_key is already registered (prevents double-@cached for the same signature).
function _register_per_sig_cache!(sig_key::String, lru, f::Function)
    haskey(PER_SIG_CACHES, sig_key) &&
        error("@cached: a global cache is already registered for $sig_key. ",
              "@cached can only be used once per signature.")
    PER_SIG_CACHES[sig_key] = lru
    push!(get!(_FUNC_TO_SIG_KEYS, f, String[]), sig_key)
    return lru
end
