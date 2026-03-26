using Cached
using LRUCache
using Test

# -------------------------------------------------------------------------
# Test functions defined at top level (each @cached call must be unique)
# -------------------------------------------------------------------------

# Basic function: squares its argument, counts invocations
const _basic_calls = Ref(0)
@cached function _test_basic(x)
    _basic_calls[] += 1
    return x^2
end

# Function with return type annotation
@cached function _test_typed(x)::Int
    return x + 1
end

# Function with a where clause
@cached function _test_where(x::T) where {T <: Number}
    return T(x * 2)
end

# Varargs function
@cached function _test_varargs(x, rest...)
    return (x, rest)
end

# Two-argument function (tests tuple key)
const _twoarg_calls = Ref(0)
@cached function _test_twoarg(x, y)
    _twoarg_calls[] += 1
    return x + y
end

# Function used for CacheStyle override tests
const _override_calls = Ref(0)
@cached function _test_override(x)
    _override_calls[] += 1
    return x
end

# Override: NoCache for String arguments
Cached.CacheStyle(::typeof(_test_override), ::String) = NoCache()

# Function used for TaskLocalCache tests
const _tasklocal_calls = Ref(0)
@cached function _test_tasklocal(x)
    _tasklocal_calls[] += 1
    return x
end

# Override: TaskLocalCache with Dict for _test_tasklocal
Cached.CacheStyle(::typeof(_test_tasklocal), args...) = TaskLocalCache{Dict{Any,Any}}()

# Anonymous typed arg: f(::SomeType)
struct _AnonTestType
    val::Int
end
const _anon_calls = Ref(0)
@cached function _test_anon(::_AnonTestType)
    _anon_calls[] += 1
    return 42
end

# -------------------------------------------------------------------------
# Tests
# -------------------------------------------------------------------------

@testset "Cached.jl" begin

    @testset "GlobalLRUCache — basic caching" begin
        _basic_calls[] = 0
        empty_globalcaches!()

        r1 = _test_basic(3)
        @test r1 == 9
        @test _basic_calls[] == 1

        r2 = _test_basic(3)   # cache hit
        @test r2 == 9
        @test _basic_calls[] == 1  # implementation not called again

        _test_basic(4)
        @test _basic_calls[] == 2  # different key → cache miss
    end

    @testset "GLOBAL_CACHES registration" begin
        @test haskey(GLOBAL_CACHES, _test_basic)
        @test GLOBAL_CACHES[_test_basic] isa LRU
    end

    @testset "NoCache bypasses caching" begin
        _basic_calls[] = 0
        empty_globalcaches!()

        _test_basic(NoCache(), 5)
        _test_basic(NoCache(), 5)
        @test _basic_calls[] == 2  # called every time
    end

    @testset "CacheStyle override" begin
        _override_calls[] = 0
        empty_globalcaches!()

        # Int argument → GlobalLRUCache, should cache
        _test_override(1)
        _test_override(1)
        @test _override_calls[] == 1

        # String argument → NoCache, should not cache
        _test_override("hello")
        _test_override("hello")
        @test _override_calls[] == 3  # 1 from above + 2 uncached calls
    end

    @testset "TaskLocalCache — same task hits cache" begin
        _tasklocal_calls[] = 0

        _test_tasklocal(99)
        _test_tasklocal(99)
        @test _tasklocal_calls[] == 1  # second call is a hit
    end

    @testset "TaskLocalCache — different tasks have independent caches" begin
        _tasklocal_calls[] = 0

        t1_result = Ref{Any}(nothing)
        t2_result = Ref{Any}(nothing)

        t1 = @async begin
            _test_tasklocal(42)
            _test_tasklocal(42)  # hit within same task
            t1_result[] = _tasklocal_calls[]
        end
        t2 = @async begin
            _test_tasklocal(42)  # independent cache → miss
            t2_result[] = _tasklocal_calls[]
        end
        wait(t1); wait(t2)
        # Total calls must be ≥ 2 (each task has its own cache)
        @test _tasklocal_calls[] >= 2
    end

    @testset "Varargs" begin
        empty_globalcaches!()

        r1 = _test_varargs(1, 2, 3)
        @test r1 == (1, (2, 3))

        # Same call → cache hit (same object returned)
        r2 = _test_varargs(1, 2, 3)
        @test r2 === r1

        # Different varargs → different key
        r3 = _test_varargs(1, 2)
        @test r3 != r1
    end

    @testset "Two-argument tuple key" begin
        _twoarg_calls[] = 0
        empty_globalcaches!()

        _test_twoarg(1, 2)
        _test_twoarg(1, 2)
        @test _twoarg_calls[] == 1

        _test_twoarg(2, 1)   # different key
        @test _twoarg_calls[] == 2
    end

    @testset "Anonymous typed arg" begin
        _anon_calls[] = 0
        empty_globalcaches!()

        a = _AnonTestType(7)
        _test_anon(a)
        _test_anon(a)
        @test _anon_calls[] == 1  # second call is a cache hit

        b = _AnonTestType(9)
        _test_anon(b)
        @test _anon_calls[] == 2  # different key
    end

    @testset "Return type annotation" begin
        empty_globalcaches!()
        r = _test_typed(3)
        @test r === 4
        @test r isa Int
    end

    @testset "where clause" begin
        empty_globalcaches!()
        # Use values that are not `isequal` so they get independent cache entries.
        # isequal(3, 3.0) == true in Julia, so they share a cache slot;
        # use Int32 vs Float64 to get truly distinct keys.
        r_int   = _test_where(Int32(3))
        r_float = _test_where(3.5)       # 3.5 has no integer-equal counterpart
        @test r_int   == Int32(6)
        @test r_int   isa Int32
        @test r_float == 7.0
        @test r_float isa Float64
    end

    @testset "set_cache_size!" begin
        lru = GLOBAL_CACHES[_test_basic]
        set_cache_size!(_test_basic, 999)
        @test lru.maxsize == 999
        @test !Cached._is_bytesize(lru)
    end

    @testset "set_cache_bytesize!" begin
        lru = GLOBAL_CACHES[_test_basic]
        set_cache_bytesize!(_test_basic, 10_000_000)
        @test lru.maxsize == 10_000_000
        @test Cached._is_bytesize(lru)

        # Switching back to count-based should clear entries
        empty!(lru)
        lru[(:sentinel,)] = 1  # manually insert
        set_cache_size!(_test_basic, 100)
        @test length(lru) == 0  # switched mode → cleared
        @test !Cached._is_bytesize(lru)
    end

    @testset "set_cache_size!/bytesize! on unregistered function → error" begin
        g(x) = x
        @test_throws ArgumentError set_cache_size!(g, 100)
        @test_throws ArgumentError set_cache_bytesize!(g, 1000)
    end

    @testset "empty_globalcaches!" begin
        _basic_calls[] = 0
        _test_basic(77)
        @test length(GLOBAL_CACHES[_test_basic]) > 0

        empty_globalcaches!()
        @test length(GLOBAL_CACHES[_test_basic]) == 0

        # After empty, next call is a miss
        _test_basic(77)
        @test _basic_calls[] == 2  # was 1 before empty, now 2
    end

    @testset "global_cache_info smoke test" begin
        buf = IOBuffer()
        @test_nowarn global_cache_info(buf)
        output = String(take!(buf))
        @test occursin("Cache Usage Summary", output)
    end

    @testset "Error cases — macro expansion" begin
        # keyword arguments
        @test_throws Exception @eval @cached function _test_err_kw(x; y = 1)
            x + y
        end

        # default values
        @test_throws Exception @eval @cached function _test_err_default(x, y = 0)
            x + y
        end
    end

    @testset "Error case — double registration" begin
        # First registration succeeds; second must be a separate @eval so the first
        # one runs to completion (and updates GLOBAL_CACHES) before the second macro
        # is expanded — allowing the check to fire at macro-expansion time.
        @eval @cached function _test_double_reg_b(x); x; end
        @test_throws Exception @eval @cached function _test_double_reg_b(x); x * 2; end
    end

end
