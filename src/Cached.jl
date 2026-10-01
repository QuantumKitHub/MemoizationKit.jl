module Cached

export LRU, ClockCache

using Base: @lock

include("containers/interface.jl")
include("containers/lru.jl")
include("containers/clock.jl")

end # module Cached
