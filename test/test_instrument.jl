using Test
using MemoizationKit
using MemoizationKit: instrument, instrument_label

# A module owning cached functions, instrumented by hand to record the phases
module Traced
    using MemoizationKit
    const LOG = Symbol[]
    const calls = Ref(0)
    @cached f(x) = (calls[] += 1; x + 1)
    @cached nocache(x) = (calls[] += 1; x)
    MemoizationKit.CacheStyle(::typeof(nocache), ::Int) = NoCache()
    @cached tasklocal(x) = (calls[] += 1; x)
    MemoizationKit.CacheStyle(::typeof(tasklocal), ::Int) = TaskLocalCache{LRU}()
    struct Scale
        a::Int
    end
    @cached (s::Scale)(x) = (calls[] += 1; s.a * x)

    function MemoizationKit.instrument(f, ::Val{phase}, thunk, ::Val{fullname(@__MODULE__)}) where {phase}
        push!(LOG, Symbol(:enter_, phase))
        r = thunk()
        push!(LOG, Symbol(:leave_, phase))
        return r
    end
end

takelog!() = (l = copy(Traced.LOG); empty!(Traced.LOG); l)
ncalls(f) = (before = Traced.calls[]; r = f(); (r, Traced.calls[] - before))

const MISS = [:enter_lookup, :enter_compute, :leave_compute, :leave_lookup]
const HIT = [:enter_lookup, :leave_lookup]
const COMPUTE = [:enter_compute, :leave_compute]

@testset "phases nest" begin
    @test MemoizationKit._ownerval(Traced.Scale) === Val(fullname(Traced))
    @test MemoizationKit._owner(Traced) === Traced # outside packages, modules own their functions
    @test MemoizationKit._owner(Base.Iterators) === Base && MemoizationKit._owner(Base) === Base
    @test MemoizationKit._ownerval(typeof(Base.Iterators.flatten)) === Val((:Base,))
    @test ncalls(() -> Traced.f(1)) == (2, 1) && takelog!() == MISS
    @test ncalls(() -> Traced.f(1)) == (2, 0) && takelog!() == HIT
    @test ncalls(() -> uncached(Traced.f, 1)) == (2, 1) && isempty(takelog!())

    @test ncalls(() -> Traced.nocache(1)) == (1, 1) && takelog!() == COMPUTE
    @test ncalls(() -> Traced.nocache(1)) == (1, 1) && takelog!() == COMPUTE

    @test ncalls(() -> Traced.tasklocal(1)) == (1, 1) && takelog!() == MISS
    @test ncalls(() -> Traced.tasklocal(1)) == (1, 0) && takelog!() == HIT

    @test ncalls(() -> Traced.Scale(2)(3)) == (6, 1) && takelog!() == MISS
    @test ncalls(() -> Traced.Scale(2)(3)) == (6, 0) && takelog!() == HIT
    @test ncalls(() -> uncached(Traced.Scale(2), 3)) == (6, 1) && isempty(takelog!())

    @test @inferred(Traced.f(2)) == 3
    @test @inferred(Traced.nocache(2)) == 2
    @test @inferred(Traced.Scale(2)(2)) == 4
    empty!(Traced.LOG)
end

@cached plain(x) = x^2
@cached plain_nocache(x)::Int = x
MemoizationKit.CacheStyle(::typeof(plain_nocache), ::Int) = NoCache()
allocs(f, x) = (f(x); @allocated f(x)) # in a function, as Julia 1.10 allocates at top level
@cached fresh(x::Int) = x # first compiled inside a caller, where Julia 1.10 could box closures
sumfresh(xs) = sum(fresh, xs)

@testset "default hook costs nothing" begin
    @test instrument(plain, Val(:lookup), () -> 1, MemoizationKit._ownerval(typeof(plain))) == 1
    @test @inferred(plain(3)) == 9
    @test allocs(plain, 3) == 0
    @test @inferred(plain_nocache(3)) == 3
    @test allocs(plain_nocache, 3) == 0
    @test allocs(sumfresh, [1, 2]) == 0
end

@testset "labels" begin
    @test instrument_label(plain, Val(:lookup)) == "lookup plain"
    @test instrument_label(Traced.Scale(1), Val(:compute)) == "compute Scale"
end

@testset "error hints without TimerOutputs" begin
    # a fresh process with MemoizationKit only, since this one loads TimerOutputs below
    mktempdir() do env
        code = """
        using Pkg
        Pkg.activate($(repr(env)); io = devnull)
        Pkg.develop(path = $(repr(pkgdir(MemoizationKit))); io = devnull)
        using MemoizationKit
        for call in (() -> enable_cache_timers!(Main), () -> disable_cache_timers!(Main))
            try
                call()
            catch e
                println(e isa MethodError, " ", sprint(showerror, e))
            end
        end
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no -e $code`,
            "JULIA_PKG_OFFLINE" => "true", "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ";" : ":"), "JULIA_PROJECT" => nothing,
        )
        out = read(cmd, String)
        for f in ("enable_cache_timers!", "disable_cache_timers!")
            @test occursin("true MethodError: no method matching $f(", out)
            @test occursin("`$f` needs TimerOutputs.jl: run `using TimerOutputs` first", out)
        end
    end
end

using TimerOutputs: TimerOutputs, TimerOutput

module A
    using MemoizationKit
    @cached f(x::Int) = x + 1
end

module B
    using MemoizationKit
    using ..A: A
    struct BType end
    @cached A.f(::BType) = 0 # owned by A
    @cached g(x) = x
    MemoizationKit.instrument_label(::typeof(g), ::Val{:lookup}) = "my lookup g"
end

# calls of the (nested) section `labels`, 0 if absent
section_calls(to, labels...) = haskey(to, first(labels)) ? TimerOutputs.ncalls(to[labels...]) : 0

hit_f() = A.f(1)
# methods of `instrument` defined by the extension
ntimed() = count(m -> m.module === Base.get_extension(MemoizationKit, :MemoizationKitTimerOutputsExt), methods(instrument))

const to = TimerOutput()
hit_f() # compiled before enabling
# enabling takes effect from the next top-level statement on
enable_cache_timers!(A, to)

@testset "timers per owner module" begin
    @test Base.get_extension(MemoizationKit, :MemoizationKitTimerOutputsExt) !== nothing
    @test A.f(1) == 2 && A.f(2) == 3 && A.f(B.BType()) == 0 && hit_f() == 2
    @test section_calls(to, "lookup f") == 4
    @test section_calls(to, "lookup f", "compute f") == 2
    @test B.g(1) == 1 && !haskey(to, "lookup g") && !haskey(to, "my lookup g")
    @test @inferred(A.f(1)) == 2
    @test isempty(Test.detect_ambiguities(MemoizationKit))
end

const to2 = TimerOutput()
enable_cache_timers!(A, to2) # replaces `to`
enable_cache_timers!(B, to2)

@testset "replacing the timer, labels" begin
    n = section_calls(to, "lookup f")
    @test A.f(1) == 2 && section_calls(to, "lookup f") == n && section_calls(to2, "lookup f") == 1
    @test B.g(2) == 2 && B.g(2) == 2
    @test section_calls(to2, "my lookup g") == 2 && section_calls(to2, "my lookup g", "compute g") == 1
    @test ntimed() == 2
end

disable_cache_timers!(A)
disable_cache_timers!(A) # no-op
disable_cache_timers!(B)

@testset "disabling restores the default" begin
    n = section_calls(to2, "lookup f")
    @test A.f(1) == 2 && hit_f() == 2 && section_calls(to2, "lookup f") == n
    @test ntimed() == 0
    @test @inferred(hit_f()) == 2
    @test allocs(A.f, 1) == 0
    @test allocs(B.g, 2) == 0
end

@testset "world age" begin
    to3 = TimerOutput()
    enable_cache_timers!(A, to3)
    @test invokelatest(hit_f) == 2 && section_calls(to3, "lookup f") == 1
    disable_cache_timers!(A)
    @test invokelatest(hit_f) == 2 && section_calls(to3, "lookup f") == 1
end
