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

@cached fib(n::Int) = n <= 2 ? big(1) : fib(n - 1) + fib(n - 2)

@cached nocache(x) = counting(x)
Cached.CacheStyle(::typeof(nocache), x::String) = NoCache()

@cached tasklocal(x) = counting(x)
Cached.CacheStyle(::typeof(tasklocal), x::Int) = TaskLocalCache{LRU}()
Cached.CacheStyle(::typeof(tasklocal), x::Symbol) = TaskLocalCache{Dict}()

@cached sized(x) = counting(x)
@cached manytypes(x) = counting(x)

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
    @test any(i -> i.type == ClockCache{Tuple{Int}, Vector{Int}}, cache_info(dependent))
    @test only(cache_info(converted)).type == ClockCache{Tuple{Int}, Float64}
    # without annotation the value type is inferred, falling back to `Any` if not concrete
    @test any(i -> i.type == ClockCache{Tuple{Int}, Int}, cache_info(basic))
    unstable(1)
    unstable(-1)
    @test only(cache_info(unstable)).type == ClockCache{Tuple{Int}, Any}
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
    @test isempty(cache_info(tasklocal))
    @test_throws ArgumentError GlobalCache{Dict}()
end

@testset "limits and management" begin
    for i in 1:20
        sized(i)
    end
    set_cache_size!(sized, 5)
    @test only(cache_info(sized)).length == 5
    for i in 21:40
        sized(i)
    end
    @test only(cache_info(sized)).length == 5
    set_cache_size!(sized, 100; by = Returns(10)) # new size measure discards the caches
    @test isempty(cache_info(sized))
    for i in 1:20
        sized(i)
    end
    @test only(cache_info(sized)).currentsize == 100

    set_max_subcaches!(manytypes, 2)
    manytypes(1)
    manytypes(1.0)
    manytypes(:a) # drops the Int cache
    @test [i.type.parameters[1] for i in cache_info(manytypes)] == [Tuple{Float64}, Tuple{Symbol}]
    @test ncalls(() -> manytypes(1)) == (1, 1)

    empty_caches!(sized)
    @test only(cache_info(sized)).length == 0
    @test ncalls(() -> basic(3)) == (9, 0)
    empty_caches!()
    @test ncalls(() -> basic(3)) == (9, 1)
    @test sprint(show, MIME"text/plain"(), first(cache_info(basic))) isa String
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
    @test only(cache_info(shared)).length == 100
end

@testset "macro errors" begin
    @test_throws Exception @macroexpand @cached x -> x
    @test_throws Exception @macroexpand @cached 1 + 1
end
