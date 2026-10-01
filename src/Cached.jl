module Cached

export @cached, uncached
export CacheStyle, NoCache, GlobalCache, GlobalLRUCache, TaskLocalCache
export LRU, ClockCache
export cache_info, empty_caches!, set_cache_size!, set_cache_preferences!
export cache_dashboard

# documented API that is used qualified, e.g. by overloading `Cached.cachesize`
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("public AbstractCache, cache_stats, cachesize, implementation"))
end

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
