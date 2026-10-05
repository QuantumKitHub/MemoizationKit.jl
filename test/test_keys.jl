using Test
using Cached

lenhash(x, seed) = hash(length(x), seed)
lenequal(x, y) = isequal(length(x), length(y))
makeequal(n) = (x, y) -> isequal(mod(x, n), mod(y, n))
makehash(n) = (x, seed) -> hash(mod(x, n), seed)

struct LengthHash end
(::LengthHash)(x, seed) = lenhash(x, seed)
struct LengthEqual end
(::LengthEqual)(x, y) = lenequal(x, y)

@testset "Hashed" begin
    @test parent(@inferred Hashed(42)) === 42
    @test hash(Hashed(42)) == hash(42)
    a = @inferred Hashed([1, 2], lenhash, lenequal)
    b = Hashed([3, 4], lenhash, lenequal)
    @test @inferred isequal(a, b)
    @test a == b && !isequal(a, Hashed([1], lenhash, lenequal))
    for seed in (UInt(0), typemax(UInt))
        @test hash(a, seed) == hash(b, seed)
    end
    @test Dict(a => 7)[b] == 7
    @test isequal(Hashed([1], LengthHash(), LengthEqual()), Hashed([2], LengthHash(), LengthEqual()))

    # Closure types alone do not identify their policies.
    eq2, eq3 = makeequal(2), makeequal(3)
    hash2, hash3 = makehash(2), makehash(3)
    @test typeof(eq2) === typeof(eq3) && typeof(hash2) === typeof(hash3)
    @test !isequal(Hashed(1, hash2, eq2), Hashed(3, hash2, eq3))
    @test !isequal(Hashed(3, hash2, eq3), Hashed(1, hash2, eq2))
    @test !isequal(Hashed(1, hash2, eq2), Hashed(1, hash3, eq2))
    @test !isequal(Hashed(1), Hashed(1, hash2))
    @test !isequal(Hashed([1], lenhash), a)
end
