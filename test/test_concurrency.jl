using Test
using Random
using Cached
using Cached: cache_stats, LocalClockCache

# Every value is a function of its key, so any value returned for the wrong key is detected.
expected(k::Int) = 3k
expected(k::NTuple{4, Int}) = (sum(k), k[1])
expected(k::String) = length(k)
expected(k::Tuple{Vector{Int}, Symbol}) = (sum(k[1]), k[2])

function randkey(rng, n)
    i = rand(rng, 1:n)
    r = rand(rng)
    return r < 0.4 ? i : r < 0.7 ? (i, i + 1, -i, 2i) : r < 0.85 ? string(i) : ([i, 1], :s)
end

# Many tasks doing every operation at once, checking each returned value; returns the number
# of `get!` calls and whether all values were correct.
function stress!(c, ntasks, niter; nkeys = 500, maxsizes = (8, 64, 256))
    gets = Threads.Atomic{Int}(0)
    ok = Threads.Atomic{Bool}(true)
    @sync for t in 1:ntasks
        Threads.@spawn begin
            rng = Xoshiro(t)
            n = 0
            for _ in 1:niter
                k = randkey(rng, nkeys)
                r = rand(rng)
                if r < 0.8
                    n += 1
                    isequal(get!(() -> expected(k), c, k), expected(k)) || (ok[] = false)
                elseif r < 0.9
                    v = get(c, k, nothing)
                    v === nothing || isequal(v, expected(k)) || (ok[] = false)
                elseif r < 0.95
                    c[k] = expected(k)
                elseif r < 0.99
                    delete!(c, k)
                elseif r < 0.995
                    resize!(c; maxsize = rand(rng, maxsizes))
                elseif r < 0.997
                    empty!(c)
                else
                    all(((k, v),) -> isequal(v, expected(k)), c) || (ok[] = false)
                end
            end
            Threads.atomic_add!(gets, n)
        end
    end
    return gets[], ok[]
end

const NTASKS = 4 * Threads.nthreads()

@testset "$C: concurrent stress" for C in (LRU, ClockCache, LocalClockCache)
    for by in (nothing, x -> 1 + (x isa Tuple ? 1 : 0))
        c = C{Any, Any}(; maxsize = 64, by)
        gets, ok = stress!(c, NTASKS, 20_000)
        @test ok
        s = cache_stats(c)
        @test s.hits + s.misses == gets
        @test s.currentsize <= s.maxsize
        @test length(c) == length(collect(c)) == s.length
        @test all(((k, v),) -> isequal(v, expected(k)), c)
        @test s.currentsize == (by === nothing ? length(c) : sum(by(v) for (k, v) in c; init = 0))
    end
end

# Many readers of a few hot keys while a writer churns the rest of the cache, so that the
# lock-free table is rebuilt and entries are evicted under the readers.
@testset "ClockCache: hits during rebuilds" begin
    c = ClockCache{Any, Any}(; maxsize = 2_000)
    ok = Threads.Atomic{Bool}(true)
    done = Threads.Atomic{Bool}(false)
    @sync begin
        for t in 1:max(1, Threads.nthreads() - 1)
            Threads.@spawn while !done[]
                k = mod(t, 8)
                get!(() -> 3k, c, k) == 3k || (ok[] = false)
                v = get(c, (k, k + 1, -k, 2k), nothing)
                v === nothing || v == expected((k, k + 1, -k, 2k)) || (ok[] = false)
                yield() # lets the writer run when there is a single thread
            end
        end
        Threads.@spawn begin
            rng = Xoshiro(0)
            for i in 1:100_000
                k = (i, i + 1, -i, 2i)
                get!(() -> expected(k), c, k)
                i % 25_000 == 0 && empty!(c)
                i % 7_919 == 0 && resize!(c; maxsize = rand(rng, 100:3_000))
            end
            done[] = true
        end
    end
    @test ok[]
    @test all(((k, v),) -> isequal(v, expected(k)), c)
end

@cached shared(x::Int) = x^2
Cached.CacheStyle(::typeof(shared), ::Int) = GlobalCache{ClockCache}()
@cached tasklocal(x::Int) = x^2
Cached.CacheStyle(::typeof(tasklocal), ::Int) = TaskLocalCache{ClockCache}()

@testset "@cached with $f" for f in (shared, tasklocal)
    @test @inferred(f(3)) == 9
    f(4)
    @test (@allocated f(4)) == 0
end

@testset "containers of @cached" begin
    c = only(cache_info(shared)).second
    @test c isa ClockCache{Any, Any}
    @test cache_stats(c).misses == 2 && cache_stats(c).hits >= 1
    @test Cached._container(tasklocal, TaskLocalCache{ClockCache}(), (1,), Int) isa LocalClockCache{Any, Any}
end
