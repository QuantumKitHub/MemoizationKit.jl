module CachedTimerOutputsExt

# Timing of cached functions with TimerOutputs, per module owning them, see
# `Cached.enable_cache_timers!`. Enabling evaluates a method of `Cached.instrument` for the owner
# into this module, recompiling the callers of its functions; disabling deletes it again, so
# that the default `thunk()` compiles away as before.

using Cached: Cached, instrument, instrument_label
using TimerOutputs: TimerOutput, timeit, get_defaulttimer

function Cached.enable_cache_timers!(M::Module, timer::TimerOutput = get_defaulttimer())
    ccall(:jl_generating_output, Cint, ()) == 1 &&
        error("`enable_cache_timers!` cannot be used during precompilation")
    # replacing the method by overwriting it would bring back the old one on deletion
    Cached.disable_cache_timers!(M)
    @eval Cached.instrument(f, phase, thunk, ::Val{$(fullname(Cached._owner(M)))}) =
        timeit(thunk, $timer, instrument_label(f, phase))
    return nothing
end

function Cached.disable_cache_timers!(M::Module)
    m = which(instrument, Tuple{Any, Any, Any, Val{fullname(Cached._owner(M))}})
    m.module === CachedTimerOutputsExt && Base.delete_method(m)
    return nothing
end

end # module CachedTimerOutputsExt
