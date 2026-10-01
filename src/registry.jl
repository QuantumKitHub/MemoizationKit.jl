# -------------------------------------------------------------------------
# Cache registry
# -------------------------------------------------------------------------

# Two-level table: function → (concrete arg type → LRU).
# The inner IdDict is initialised at macro eval time (by _register_static_sig!) and
# populated lazily on the first call for each concrete argument type.
const GLOBAL_CACHE_TABLE = IdDict{Function, IdDict{Type, Any}}()

# Static-signature duplicate detection.  Populated at macro eval time so that
# calling @cached twice with the same static signature throws an error.
const _REGISTERED_STATIC_SIGS = Set{String}()

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

# Called from macro-generated code at module load time.
# Registers the static signature key for duplicate detection and initialises
# the inner IdDict for function f in GLOBAL_CACHE_TABLE.
function _register_static_sig!(sig_key::String, f::Function)
    sig_key in _REGISTERED_STATIC_SIGS &&
        error("@cached: a global cache is already registered for $sig_key. ",
              "@cached can only be used once per signature.")
    push!(_REGISTERED_STATIC_SIGS, sig_key)
    get!(GLOBAL_CACHE_TABLE, f) do; IdDict{Type, Any}(); end
    return nothing
end

# Called from the fallback method on the first invocation for a concrete type T.
# Creates LRU{T,V} and stores it in GLOBAL_CACHE_TABLE[f][T].
function _ensure_global_lru!(f::Function, T::Type, ::Type{V}) where V
    func_caches = GLOBAL_CACHE_TABLE[f]
    return get!(func_caches, T) do
        _make_typed_global_lru(T, V)
    end
end

# Called from the fallback method after creating the LRU.
# Core.eval's a specialized f(::GlobalLRUCache, arg::T) method into mod,
# embedding f, T, and lru by value (true-closure pattern; not precompilation-safe).
function _eval_global_method!(f::Function, T::Type, lru, mod::Module)
    fname = nameof(f)
    m = :(
        function $fname(::$GlobalLRUCache, arg::$T)
            get!($lru, arg) do
                $f($(NoCache()), arg)
            end
        end
    )
    Core.eval(mod, m)
end
