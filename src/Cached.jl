module Cached

# -------------------------------------------------------------------------
# Exports
# -------------------------------------------------------------------------

export CacheStyle, NoCache, TaskLocalCache, GlobalLRUCache
export @cached
export GLOBAL_CACHE_TABLE, DEFAULT_GLOBALCACHE_SIZE, GLOBALCACHE_SIZE_FUNCTION
export caches_for, empty_globalcaches!, global_cache_info, set_cache_size!, set_cache_bytesize!
export set_default_cache_bytesize!

# -------------------------------------------------------------------------
# Imports
# -------------------------------------------------------------------------

using LRUCache
using Preferences
using Printf: @sprintf

# -------------------------------------------------------------------------
# Includes
# -------------------------------------------------------------------------

include("types.jl")
include("preferences.jl")
include("registry.jl")
include("api.jl")
include("display.jl")
include("macro.jl")

end # module Cached
