using Test
using Aqua
using Cached

@testset "Aqua" begin
    Aqua.test_all(Cached)
end

@static if VERSION >= v"1.11.0-DEV.469"
    @testset "public API" begin
        for name in (:AbstractCache, :cache_stats, :cachesize, :implementation, :instrument_label, :diskversion, :disk_artifact, :cachekey)
            @test Base.ispublic(Cached, name)
        end
    end
end
