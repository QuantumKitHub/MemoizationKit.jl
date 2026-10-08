# Timing

```@meta
CurrentModule = MemoizationKit
```

With [TimerOutputs.jl](https://github.com/KristofferC/TimerOutputs.jl) loaded, [`enable_cache_timers!`](@ref) records the time spent in the cached functions of a package, in sections per function:

- `lookup f` wraps the whole cache lookup, hit or miss;
- `compute f` wraps the call of the implementation: nested in `lookup f` on a miss, and on its own under [`NoCache`](@ref);
- `disk f`, for functions with a [disk cache](disk.md), wraps the disk lookup after a RAM miss, with `compute f` nested in it when the disk misses too.

```@example timer
using MemoizationKit, TimerOutputs

@cached weights(a, b, c) = a + b * c
@cached matrix(n::Int)::Matrix{Float64} = zeros(n, n)

to = TimerOutput()
enable_cache_timers!(@__MODULE__, to)   # the timer defaults to TimerOutputs' global one
for i in 1:200
    weights(1 + i % 6, 1 + (7i) % 6, 1 + (13i) % 6)
    matrix(1 + i % 10)
end
disable_cache_timers!(@__MODULE__)
to
```

Timing is off by default and adds no overhead while off.
Enabling or disabling it recompiles callers and takes effect from the next top-level statement.
If a function enables timers and calls cached functions in the same invocation, use `invokelatest` for those calls.
Enabling a package again replaces its timer.
Do not enable timers during precompilation.

What counts is the package that owns the function (including its submodules), not where `@cached` was written; modules outside packages, such as in the REPL, count separately.
For instance, if `MyPackage` adds `@cached` methods to a function `OtherPackage.f`, then `enable_cache_timers!(OtherPackage)` times them, and `enable_cache_timers!(MyPackage)` does not.
A package that wants all of its cached functions timed enables the packages that own them:

```@example owners
using MemoizationKit, TimerOutputs # hide
module MyPackage # hide
    function enable_timers! end # hide
end # hide
module OtherPackage # hide
    using MemoizationKit # hide
    @cached f(x) = x^2 # hide
end # hide
TIMER = TimerOutput() # hide
function MyPackage.enable_timers!()
    enable_cache_timers!(MyPackage, TIMER)
    enable_cache_timers!(OtherPackage, TIMER)
end

MyPackage.enable_timers!()
OtherPackage.f(2)
disable_cache_timers!(MyPackage)
disable_cache_timers!(OtherPackage)
TIMER
```

The labels come from [`MemoizationKit.instrument_label`](@ref), `"lookup f"` and `"compute f"` by default; overload it to pick your own:

```@example timer
MemoizationKit.instrument_label(::typeof(weights), ::Val{:lookup}) = "cache: weights"
MemoizationKit.instrument_label(weights, Val(:lookup))
```
