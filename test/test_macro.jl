using Test
using Cached
using Cached: implementation

const calls = Ref(0)
counting(x) = (calls[] += 1; x)

# --- definitions under test (each method can only be @cached once) ---

"Docstring of `basic`."
@cached basic(x) = counting(x^2)

@cached function full(x, y::Int = 2, rest...; k = 1, kw...)
    return counting(x * y + k + length(rest) + length(kw))
end

@cached anon(::Val{N}) where {N} = counting(N)

@cached converted(x)::Float64 = counting(x)

# value type computed from a where parameter, as in TensorKit's `fsbraid`
valtype_of(::Type{T}) where {T} = Vector{T}
@cached function dependent(x::T)::valtype_of(T) where {T}
    return counting([x])
end

@cached unstable(x) = counting(x > 0 ? x : "negative")

struct Adder
    a::Int
end
@cached (f::Adder)(y) = counting(f.a + y)

struct Point
    x::Int
end
@cached Base.:+(p::Point, q::Point) = counting(Point(p.x + q.x))

module Other
    owned(x) = x
end
@cached Other.owned(x::Symbol) = counting(x)

# same name in different modules
module ClashA
    using Cached
    @cached f(x) = (:A, x)
end
module ClashB
    using Cached
    @cached f(x) = (:B, x)
end

# two modules caching their own methods of one shared function
module Shared
    fusion(x) = x
end
module SectorsA
    using Cached
    import ..Shared
    struct IrrepA end
    @cached Shared.fusion(::IrrepA) = :A
end
module SectorsB
    using Cached
    import ..Shared
    struct IrrepB end
    @cached Shared.fusion(::IrrepB) = :B
end

@cached fib(n::Int) = n <= 2 ? big(1) : fib(n - 1) + fib(n - 2)

@cached nocache(x) = counting(x)
Cached.CacheStyle(::typeof(nocache), x::String) = NoCache()

@cached tasklocal(x) = counting(x)
Cached.CacheStyle(::typeof(tasklocal), x::Int) = TaskLocalCache{LRU}()
Cached.CacheStyle(::typeof(tasklocal), x::Symbol) = TaskLocalCache{Dict}()
Cached.CacheStyle(::typeof(tasklocal), x::Float64) = TaskLocalCache() # default container
Cached.CacheStyle(::typeof(tasklocal), x::String) = GlobalCache()

@cached sized(x) = counting(x)
@cached manytypes(x) = counting(x)

caches(f) = last.(cache_info(f))
rettype(f, T) = only(Base.return_types(f, T)) # `Base.infer_return_type` needs Julia 1.11

# returns (result, number of implementation calls)
function ncalls(f)
    before = calls[]
    r = f()
    return r, calls[] - before
end

@testset "hits and misses" begin
    @test ncalls(() -> basic(3)) == (9, 1)
    @test ncalls(() -> basic(3)) == (9, 0)
    @test ncalls(() -> basic(3.0)) == (9.0, 1) # different key type, different cache
    @test ncalls(() -> uncached(basic, 3)) == (9, 1)
    @test implementation(basic, 4) == 16
    @test occursin("Docstring of `basic`", string(@doc basic))
end

@testset "positional, default, varargs and keyword arguments" begin
    @test ncalls(() -> full(1)) == (3, 1)
    @test ncalls(() -> full(1, 2)) == (3, 0) # default filled in before the lookup
    @test ncalls(() -> full(1; k = 1)) == (3, 0)
    @test ncalls(() -> full(1, 3, :a, :b; k = 5, z = 0)) == (11, 1)
    @test ncalls(() -> full(1, 3, :a, :b; k = 5, z = 0)) == (11, 0)
    @test ncalls(() -> full(1, 3, :a, :b; k = 5, z = 1)) == (11, 1)
    @test ncalls(() -> anon(Val(4))) == (4, 1)
    @test ncalls(() -> anon(Val(4))) == (4, 0)
end

@testset "return types" begin
    @test converted(1) === 1.0
    @test dependent(1) == [1] && dependent(1) isa Vector{Int}
    @test dependent(1.5) isa Vector{Float64}
    # one untyped cache per function; the value type is recovered at the call
    @test only(caches(dependent)) isa ClockCache{Any, Any}
    @test rettype(dependent, Tuple{Int}) == Vector{Int}
    @test rettype(dependent, Tuple{Float64}) == Vector{Float64}
    @test rettype(converted, Tuple{Int}) == Float64
    # without annotation the value type is inferred, falling back to `Any` if not concrete
    @test rettype(basic, Tuple{Int}) == Int
    @test unstable(1) === 1 && unstable(-1) == "negative"
    @test rettype(unstable, Tuple{Int}) == Any
    @test length(only(caches(unstable))) == 2
end

@testset "type stability" begin
    @test @inferred(basic(5)) == 25
    @test @inferred(full(1, 2, :a; k = 2)) == 5
    @test @inferred(dependent(2)) == [2]
    @test @inferred(Adder(1)(1)) == 2
    basic(6)
    @test (@allocated basic(6)) == 0
end

@testset "callable objects, operators, foreign functions" begin
    @test ncalls(() -> Adder(1)(2)) == (3, 1)
    @test ncalls(() -> Adder(1)(2)) == (3, 0)
    @test ncalls(() -> Adder(5)(2)) == (7, 1) # instances with different fields do not share
    @test ncalls(() -> Point(1) + Point(2)) == (Point(3), 1)
    @test ncalls(() -> Point(1) + Point(2)) == (Point(3), 0)
    @test ncalls(() -> Other.owned(:a)) == (:a, 1)
    @test ncalls(() -> Other.owned(:a)) == (:a, 0)
    @test Other.owned(1) == 1 # other methods are untouched
end

@testset "functions with the same name" begin
    @test ClashA.f(1) == (:A, 1) && ClashB.f(1) == (:B, 1)
    @test ClashA.f(1) == (:A, 1) && ClashB.f(1) == (:B, 1) # cache hits stay separate
    @test length(cache_info(ClashA.f)) == length(cache_info(ClashB.f)) == 1
    @test only(caches(ClashA.f)) !== only(caches(ClashB.f))
    # printing qualifies the function by its module (from inside the module, Julia >= 1.11
    # prints it unqualified; that is Base's function printing, not tested here)
    @test occursin("ClashA.f =>", sprint(show, cache_info(ClashA.f)))
    @test occursin("ClashB.f =>", sprint(show, cache_info(ClashB.f)))

    # methods of one function cached from different modules share its cache
    @test Shared.fusion(SectorsA.IrrepA()) === :A
    @test Shared.fusion(SectorsB.IrrepB()) === :B
    @test uncached(Shared.fusion, SectorsB.IrrepB()) === :B
    @test Shared.fusion(1) == 1 # the uncached method is untouched
    @test length(only(caches(Shared.fusion))) == 2
end

@testset "recursion" begin
    @test fib(300) == big"222232244629420445529739893461909967206666939096499764990979600"
end

@testset "CacheStyle" begin
    @test ncalls(() -> nocache(1)) == (1, 1)
    @test ncalls(() -> nocache(1)) == (1, 0)
    @test ncalls(() -> nocache("a")) == ("a", 1)
    @test ncalls(() -> nocache("a")) == ("a", 1)

    @test ncalls(() -> tasklocal(1)) == (1, 1)
    @test ncalls(() -> tasklocal(1)) == (1, 0)
    @test ncalls(() -> fetch(Threads.@spawn tasklocal(1))) == (1, 1) # new task, new cache
    @test ncalls(() -> tasklocal(:a)) == (:a, 1)
    @test ncalls(() -> tasklocal(:a)) == (:a, 0)
    @test ncalls(() -> tasklocal(1.0)) == (1.0, 1)
    @test ncalls(() -> tasklocal(1.0)) == (1.0, 0)
    @test ncalls(() -> fetch(Threads.@spawn tasklocal(1.0))) == (1.0, 1)
    @test isempty(cache_info(tasklocal))
    @test ncalls(() -> tasklocal("a")) == ("a", 1)
    @test ncalls(() -> tasklocal("a")) == ("a", 0)
    @test only(caches(tasklocal)) isa Cached.DEFAULT_CONTAINER
    @test_throws ArgumentError GlobalCache{Dict}()
end

@testset "limits and management" begin
    for i in 1:20
        sized(i)
    end
    set_cache_size!(sized, 5)
    @test length(only(caches(sized))) == 5
    for i in 21:40
        sized(i)
    end
    @test length(only(caches(sized))) == 5
    set_cache_size!(sized, 100; by = Returns(10)) # new size measure discards the caches
    @test isempty(cache_info(sized))
    for i in 1:20
        sized(i)
    end
    @test Cached.cache_stats(only(caches(sized))).currentsize == 100

    # the limit is a budget for the function as a whole, all signatures together
    set_cache_size!(manytypes, 3)
    foreach(manytypes, (1, 1.0, :a, "a", 'a'))
    @test length(only(caches(manytypes))) == 3
    # keys of different types are different entries, even when `isequal`
    @test ncalls(() -> manytypes(2)) == (2, 1) && ncalls(() -> manytypes(2.0)) == (2.0, 1)
    @test ncalls(() -> manytypes(2.0)) == (2.0, 0) && manytypes(2) isa Int

    empty_caches!(sized)
    @test length(only(caches(sized))) == 0
    @test ncalls(() -> basic(3)) == (9, 0)
    empty_caches!()
    @test ncalls(() -> basic(3)) == (9, 1)
    @test occursin("ClockCache{Any, Any}(1/10000 entries", sprint(show, cache_info(basic)))
    @test all(p -> first(p) === basic, cache_info(basic))
    @test length(cache_info()) >= length(cache_info(basic)) + length(cache_info(sized))
end

@testset "concurrency" begin
    @cached function shared(x::Int)
        return 2x
    end
    ok = Threads.Atomic{Bool}(true)
    Threads.@threads for i in 1:10_000
        shared(i % 100) == 2 * (i % 100) || (ok[] = false)
    end
    @test ok[]
    @test length(only(caches(shared))) == 100
end

@testset "macro errors" begin
    @test_throws Exception @macroexpand @cached x -> x
    @test_throws Exception @macroexpand @cached 1 + 1
end
