module Cached

export @cached, uncached
export CacheStyle, NoCache, GlobalCache, GlobalLRUCache, TaskLocalCache
export LRU, ClockCache
export cache_info, empty_caches!, set_cache_size!, set_max_subcaches!

using Base: @lock
using ExprTools: ExprTools

include("containers/interface.jl")
include("containers/lru.jl")
include("containers/clock.jl")

include("cachestyle.jl")
include("registry.jl")
include("call.jl")
include("api.jl")
include("macro.jl")

end # module Cached
