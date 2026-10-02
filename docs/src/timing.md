# Timing

```@meta
CurrentModule = Cached
```

With [TimerOutputs.jl](https://github.com/KristofferC/TimerOutputs.jl) loaded, [`enable_cache_timers!`](@ref) records the time spent in the cached functions of a package, in two nested sections per function:

- `lookup f` wraps the whole cache lookup, hit or miss;
- `compute f` wraps the call of the implementation: nested in `lookup f` on a miss, and on its own under [`NoCache`](@ref);
- `disk f`, for functions with a [disk cache](disk.md), wraps the disk lookup after a RAM miss, with `compute f` nested in it when the disk misses too.

```@example timer
using Cached, TimerOutputs

@cached fsymbol(a, b, c) = a + b * c
@cached matrix(n::Int)::Matrix{Float64} = zeros(n, n)

to = TimerOutput()
enable_cache_timers!(@__MODULE__, to)   # the timer defaults to TimerOutputs' global one
for i in 1:200
    fsymbol(1 + i % 6, 1 + (7i) % 6, 1 + (13i) % 6)
    matrix(1 + i % 10)
end
disable_cache_timers!(@__MODULE__)
to
```

Timing is a debugging tool, and works like TimerOutputs' `enable_debug_timings`.
When it is off, the default, it costs nothing: a cache hit has not even an extra branch.
Enabling or disabling a package recompiles the callers of its cached functions, and takes effect from the next top-level statement on: a function that enables the timers and then calls cached functions needs `invokelatest` for those calls.
Enabling a package again replaces its timer.
Do not enable timers during precompilation.

What counts is the package that owns the function (including its submodules), not where `@cached` was written; modules outside packages, such as in the REPL, count separately.
For instance, TensorKit times its own cached functions and those of TensorKitSectors, including the `@cached` methods of `TensorKitSectors.Fsymbol` defined in SUNRepresentations:

```julia
function TensorKit.enable_timers!()
    enable_cache_timers!(TensorKit, GLOBAL_TIMER)
    enable_cache_timers!(TensorKitSectors, GLOBAL_TIMER)
end
```

The labels come from [`Cached.instrument_label`](@ref), `"lookup f"` and `"compute f"` by default; overload it to pick your own:

```julia
Cached.instrument_label(::typeof(fsbraid), ::Val{:lookup}) = "bookkeeping: cache fsbraid"
```
