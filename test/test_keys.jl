using Test
using Cached

lenhash(x, seed) = hash(length(x), seed)
lenequal(x, y) = isequal(length(x), length(y))
collisionhash(x, seed) = hash(0, seed)
makeequal(n) = (x, y) -> isequal(mod(x, n), mod(y, n))
makehash(n) = (x, seed) -> hash(mod(x, n), seed)

struct LengthHash end
(::LengthHash)(x, seed) = lenhash(x, seed)
struct LengthEqual end
(::LengthEqual)(x, y) = lenequal(x, y)

@testset "Hashed" begin
    @test parent(@inferred Hashed(42)) === 42
    @test isequal(Hashed(42), Hashed(42))
    @test !isequal(Hashed(42), Hashed(43))
    @test !isequal(Hashed(42), 42)
    @test !isequal(42, Hashed(42))
    @test isequal(Hashed(NaN), Hashed(NaN))
    @test !isequal(Hashed(0.0), Hashed(-0.0))

    a = @inferred Hashed([1, 2], lenhash, lenequal)
    b = Hashed([3, 4], lenhash, lenequal)
    c = Hashed([5], lenhash, lenequal)
    @test @inferred isequal(a, b)
    @test a == b && !(a == c)
    for seed in (UInt(0), UInt(1), typemax(UInt))
        @test hash(a, seed) == hash(b, seed)
    end
    for C in (Dict, LRU, ClockCache)
        d = C{Any, Int}()
        d[a] = 7
        @test d[b] == 7
        @test !haskey(d, c)
        # Hash collisions must still use equality.
        d[Hashed(1, collisionhash)] = 11
        d[Hashed(2, collisionhash)] = 22
        @test d[Hashed(1, collisionhash)] == 11
        @test d[Hashed(2, collisionhash)] == 22
    end
    @test isequal(Hashed([1], LengthHash(), LengthEqual()), Hashed([2], LengthHash(), LengthEqual()))

    # Closure types alone do not identify their policies.
    eq2, eq3 = makeequal(2), makeequal(3)
    hash2, hash3 = makehash(2), makehash(3)
    @test typeof(eq2) === typeof(eq3)
    @test typeof(hash2) === typeof(hash3)
    @test !isequal(Hashed(1, collisionhash, eq2), Hashed(3, collisionhash, eq3))
    @test !isequal(Hashed(3, collisionhash, eq3), Hashed(1, collisionhash, eq2))
    @test !isequal(Hashed(1, hash2, eq2), Hashed(1, hash3, eq2))
    @test !isequal(Hashed(1), Hashed(1, collisionhash))
    @test !isequal(Hashed([1], lenhash), a)
end

const COMPUTATIONS = Ref(0)
const KEYCALLS = Ref(0)
counted(x) = (COMPUTATIONS[] += 1; x)
hitallocs(f, x) = (f(x); @allocated f(x))

@cached projected(x, factor::Int = 2, rest...; offset = 0) =
    counted(factor * length(x) + length(rest) + offset)
function Cached.cachekey(::typeof(projected), x, factor, rest...; offset)
    KEYCALLS[] += 1
    return (length(x), factor, length(rest), offset)
end

@cached wrapped(x) = counted(length(x))
Cached.cachekey(::typeof(wrapped), x) = (Hashed(x, lenhash, lenequal),)

@cached merged(x::AbstractVector; label = 1) = counted(length(x))
@cached merged(x::Tuple; label = 1) = counted(length(x))
Cached.cachekey(::typeof(merged), x; label) = length(x)

@cached localprojected(x) = counted(length(x))
Cached.cachekey(::typeof(localprojected), x) = length(x)
Cached.CacheStyle(::typeof(localprojected), x) = TaskLocalCache{Dict}()

@testset "cachekey" begin
    @test Cached.cachekey(identity) === ()
    @test Cached.cachekey(identity, 1, 2) === (1, 2)
    @test Cached.cachekey(identity, 1; a = 2) === (1, (a = 2,))
    @test projected([1, 2]) == 4
    n = COMPUTATIONS[]
    @test @inferred(projected([3, 4], 2; offset = 0)) == 4
    @test COMPUTATIONS[] == n
    @test projected([3, 4], 3, :a; offset = 1) == 8
    @test projected([1, 2], 3, :b; offset = 1) == 8
    @test projected([1, 2], 3, :b; offset = 2) == 9
    @test COMPUTATIONS[] == n + 2
    nk = KEYCALLS[]
    @test uncached(projected, [3, 4], 2; offset = 0) == 4
    @test KEYCALLS[] == nk && COMPUTATIONS[] == n + 3

    @test wrapped([1, 2]) == 2
    n = COMPUTATIONS[]
    @test @inferred(wrapped([3, 4])) == 2
    @test COMPUTATIONS[] == n
    @test hitallocs(wrapped, [3, 4]) == 0
    @test wrapped([1]) == 1
    @test COMPUTATIONS[] == n + 1

    n = COMPUTATIONS[]
    @test @inferred(merged([1, 2])) == 2
    @test @inferred(merged([1.0, 2.0])) == 2
    @test @inferred(merged((3, 4))) == 2
    @test @inferred(merged((3, 4); label = 1.0)) == 2
    @test COMPUTATIONS[] == n + 1
    @test hitallocs(merged, (3, 4)) == 0

    @test localprojected([1, 2]) == 2
    n = COMPUTATIONS[]
    @test @inferred(localprojected([3, 4])) == 2
    @test COMPUTATIONS[] == n
    @test fetch(Threads.@spawn localprojected([3, 4])) == 2
    @test COMPUTATIONS[] == n + 1
end
