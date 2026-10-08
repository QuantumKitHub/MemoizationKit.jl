using Test
using MemoizationKit

@testset "precompile workload leaves no cache state" begin
    if isdefined(MemoizationKit, :_Precompile)
        workload = MemoizationKit._Precompile
        @test isempty(cache_info(workload))
        @test all(f -> parentmodule(typeof(f)) !== workload, keys(MemoizationKit.REGISTRY.functions))
        @test all(k -> parentmodule(typeof(first(k))) !== workload, keys(get(task_local_storage(), :__MemoizationKit_tasklocal__, IdDict())))
    else
        @test isempty(cache_info(MemoizationKit))
    end
    @test MemoizationKit.DISK_ENABLED[]
end

if Base.JLOptions().use_compiled_modules == 0
    @testset "source loading skips precompile helpers" begin
        @test !isdefined(MemoizationKit, :_Precompile)
    end
end
