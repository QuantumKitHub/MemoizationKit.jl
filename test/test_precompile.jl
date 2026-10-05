using Test
using Cached

@testset "precompile workload leaves no cache state" begin
    if isdefined(Cached, :_Precompile)
        workload = Cached._Precompile
        @test isempty(cache_info(workload))
        @test all(f -> parentmodule(typeof(f)) !== workload, keys(Cached.REGISTRY.functions))
        @test all(k -> parentmodule(typeof(first(k))) !== workload, keys(get(task_local_storage(), :__Cached_tasklocal__, IdDict())))
    else
        @test isempty(cache_info(Cached))
    end
    @test Cached.DISK_ENABLED[]
end

if Base.JLOptions().use_compiled_modules == 0
    @testset "source loading skips precompile helpers" begin
        @test !isdefined(Cached, :_Precompile)
    end
end
