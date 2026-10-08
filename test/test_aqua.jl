using Test
using Aqua
using MemoizationKit

@testset "Aqua" begin
    Aqua.test_all(MemoizationKit)
end

@static if VERSION >= v"1.11.0-DEV.469"
    @testset "public API" begin
        for name in (:AbstractCache, :cache_stats, :cachesize, :implementation, :instrument_label, :diskversion, :disk_artifact, :cachekey)
            @test Base.ispublic(MemoizationKit, name)
        end
    end
end
