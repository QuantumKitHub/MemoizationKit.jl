module Cached

export @cached, uncached
export CacheStyle, NoCache, GlobalCache, GlobalLRUCache, TaskLocalCache
export LRU, ClockCache
export cache_info, empty_caches!, set_cache_size!, set_max_subcaches!

using Base: @lock
using ExprTools: ExprTools
using Preferences: @load_preference, load_preference, has_preference

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
