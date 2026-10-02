# Instrumentation

```@meta
CurrentModule = Cached
```

Every call of a [`@cached`](@ref) function goes through the hook [`Cached.instrument`](@ref),
in two nested phases:

- `:lookup` wraps the whole cache lookup, hit or miss, of a [`GlobalCache`](@ref) or
  [`TaskLocalCache`](@ref);
- `:compute` wraps the call of the implementation: nested in `:lookup` on a miss, and on its
  own under [`NoCache`](@ref).

By default the hook is `thunk()` and compiles away: a cache hit costs nothing extra, not even
a branch. [`uncached`](@ref) bypasses the hook along with the cache.

## Timing with TimerOutputs

With [TimerOutputs.jl](https://github.com/KristofferC/TimerOutputs.jl) loaded,
[`enable_cache_timers!`](@ref) times the cached functions owned by a module, i.e. those with
`parentmodule(typeof(f)) === M`, in a section per function and phase:

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

Timing is a debugging tool, and works like TimerOutputs' `enable_debug_timings`: enabling or
disabling a module defines or deletes a method of `Cached.instrument` for it, which recompiles
the callers of its functions. Disabling brings back the zero-cost default. The change takes
effect from the next top-level statement on: a function that enables the timers and then calls
cached functions needs `invokelatest` for those calls. Enabling a module again replaces its
timer. Do not enable timers during precompilation.

What counts is the module that owns the function, not where `@cached` was written. For
instance, TensorKit times its own cached functions and those of TensorKitSectors, including
the `@cached` methods of `TensorKitSectors.Fsymbol` defined in SUNRepresentations:

```julia
function TensorKit.enable_timers!()
    enable_cache_timers!(TensorKit, GLOBAL_TIMER)
    enable_cache_timers!(TensorKitSectors, GLOBAL_TIMER)
end
```

The labels come from [`Cached.instrument_label`](@ref), `"lookup f"` and `"compute f"` by
default; overload it to pick your own:

```julia
Cached.instrument_label(::typeof(fsbraid), ::Val{:lookup}) = "bookkeeping: cache fsbraid"
```

## Timing with your own tools

Calls go to `Cached.instrument(f, phase, thunk, ::Val{owner})`, with
`owner = fullname(parentmodule(typeof(f)))`, which by default passes them on to
`Cached.instrument(f, phase, thunk)`, whose default is `thunk()`. Overload the four-argument
method per owner module (as [`enable_cache_timers!`](@ref) does), or the three-argument one per
function, returning the value of `thunk()`. For example, with `@timeit_debug`, which compiles
away until `TimerOutputs.enable_debug_timings(MyPackage)`:

```julia
@inline Cached.instrument(::typeof(fsbraid), ::Val{:lookup}, thunk) =
    @timeit_debug TIMER "bookkeeping: cache fsbraid" thunk()
```

Callable objects dispatch on their type, `Cached.instrument(::MyFunctor, ::Val{:compute}, thunk)`.
While the timers of the owner are enabled, they take precedence over the overloads per
function. Do not overload the four-argument method per function: it would be ambiguous with
the methods of [`enable_cache_timers!`](@ref).
