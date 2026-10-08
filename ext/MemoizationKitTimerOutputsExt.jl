module MemoizationKitTimerOutputsExt

# Timing of cached functions with TimerOutputs, per module owning them, see
# `MemoizationKit.enable_cache_timers!`. Enabling evaluates a method of `MemoizationKit.instrument` for the owner
# into this module, recompiling the callers of its functions; disabling deletes it again, so
# that the default `thunk()` compiles away as before.

using MemoizationKit: MemoizationKit, instrument, instrument_label
using TimerOutputs: TimerOutput, timeit, get_defaulttimer

function MemoizationKit.enable_cache_timers!(M::Module, timer::TimerOutput = get_defaulttimer())
    ccall(:jl_generating_output, Cint, ()) == 1 &&
        error("`enable_cache_timers!` cannot be used during precompilation")
    # replacing the method by overwriting it would bring back the old one on deletion
    MemoizationKit.disable_cache_timers!(M)
    @eval MemoizationKit.instrument(f, phase, thunk, ::Val{$(fullname(MemoizationKit._owner(M)))}) =
        timeit(thunk, $timer, instrument_label(f, phase))
    return nothing
end

function MemoizationKit.disable_cache_timers!(M::Module)
    m = which(instrument, Tuple{Any, Any, Any, Val{fullname(MemoizationKit._owner(M))}})
    m.module === MemoizationKitTimerOutputsExt && Base.delete_method(m)
    return nothing
end

end # module MemoizationKitTimerOutputsExt
