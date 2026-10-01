module Cached

export @cached, uncached
export CacheStyle, NoCache, GlobalCache, GlobalLRUCache, TaskLocalCache
export LRU, ClockCache
export cache_info, empty_caches!, set_cache_size!, set_max_subcaches!, set_cache_preferences!

using Base: @lock
using ExprTools: ExprTools
using Preferences: @load_preference, load_preference, has_preference, set_preferences!, delete_preferences!

include("containers/interface.jl")
include("containers/lru.jl")
include("containers/clock.jl")

include("registry.jl")
include("preferences.jl")
include("cachestyle.jl")
include("call.jl")
include("api.jl")
include("macro.jl")

end # module Cached
