using Test
using Aqua
using Cached

@testset "Aqua" begin
    Aqua.test_all(Cached)
end
