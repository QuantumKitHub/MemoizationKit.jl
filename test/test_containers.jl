using Test
using Cached
using Cached: AbstractCache, cache_stats

# The example policy of docs/src/interface.md, also run through the generic tests below.
mutable struct FIFO{K, V} <: AbstractCache{K, V}
    const slots::Cached.Slots{V}
    const queue::Vector{Int} # occupied slots, oldest first
end
FIFO{K, V}(; maxsize = 10_000, by = nothing) where {K, V} = FIFO{K, V}(Cached.Slots{V}(maxsize, by), Int[])
Cached.admit!(c::FIFO, i::Int) = push!(c.queue, i)
Cached.touch!(::FIFO, ::Int) = nothing
Cached.victim(c::FIFO) = first(c.queue)
Cached.forget!(c::FIFO, i::Int) = deleteat!(c.queue, findfirst(==(i), c.queue))

const CACHETYPES = (LRU, ClockCache, FIFO)

@testset "$C: basic interface" for C in CACHETYPES
    c = C{Int, String}(; maxsize = 3)
    @test c isa AbstractCache{Int, String}
    @test isempty(c)
    @test get!(() -> "one", c, 1) == "one"
    @test get!(() -> error("not called"), c, 1) == "one"
    @test cache_stats(c).hits == 1 && cache_stats(c).misses == 1
    c[2] = "two"
    @test c[2] == "two"
    @test get(c, 3, nothing) === nothing
    @test_throws KeyError c[3]
    @test haskey(c, 2) && !haskey(c, 3)
    @test Dict(c) == Dict(1 => "one", 2 => "two")
    delete!(c, 1)
    @test !haskey(c, 1) && length(c) == 1
    c[2] = "deux" # overwrite
    @test c[2] == "deux" && length(c) == 1
    empty!(c)
    @test isempty(c) && cache_stats(c).currentsize == 0
    # keys are converted
    @test get!(() -> "x", c, Int32(5)) == "x" && haskey(c, 5)
end

@testset "$C: count limit" for C in CACHETYPES
    c = C{Int, Int}(; maxsize = 10)
    for i in 1:100
        get!(() -> i^2, c, i)
        @test length(c) <= 10
    end
    @test length(c) == 10
    @test all(k -> c[k] == k^2, keys(Dict(c)))
    resize!(c; maxsize = 4)
    @test length(c) == 4
    @test cache_stats(c).currentsize == 4
    empty!(c)
    foreach(i -> c[i] = i, 1:20) # refills the freed slots, then evicts
    @test length(c) == 4 && all(((k, v),) -> k == v, c)
    resize!(c; maxsize = 0)
    @test isempty(c)
    get!(() -> 1, c, 1)
    @test isempty(c) # nothing fits
end

@testset "LRU: exact eviction order" begin
    c = LRU{Int, Int}(; maxsize = 3)
    for i in 1:3
        c[i] = i
    end
    c[1] # 1 becomes most recent, 2 is now least recent
    c[4] = 4
    @test !haskey(c, 2) && haskey(c, 1) && haskey(c, 3) # haskey does not count as use
    c[5] = 5 # recency is now 4, 1, 3
    @test !haskey(c, 3) && haskey(c, 1) && haskey(c, 4)
    empty!(c)
    foreach(i -> c[i] = i, 1:3)
    c[2]
    c[4] = 4 # the order is rebuilt from scratch after `empty!`
    @test !haskey(c, 1) && haskey(c, 2)
end

@testset "ClockCache: second chance" begin
    c = ClockCache{Int, Int}(; maxsize = 3)
    for i in 1:3
        c[i] = i
    end
    c[1] # sets 1's reference bit
    c[4] = 4 # hand skips 1 (clearing its bit) and evicts 2
    @test haskey(c, 1) && !haskey(c, 2) && haskey(c, 3) && haskey(c, 4)
    c[5] = 5 # 3 has a clear bit
    @test !haskey(c, 3)
end

@testset "FIFO: insertion order, hits ignored" begin
    c = FIFO{Int, Int}(; maxsize = 3)
    foreach(i -> c[i] = i, 1:3)
    c[1]
    c[4] = 4
    @test !haskey(c, 1) && haskey(c, 2)
    delete!(c, 3)
    c[5] = 5 # fits in the freed slot
    c[6] = 6
    @test !haskey(c, 2) && haskey(c, 4) && haskey(c, 5) && haskey(c, 6)
end

@testset "$C: byte limit" for C in CACHETYPES
    c = C{Int, Vector{UInt8}}(; maxsize = 100, by = length)
    c[1] = zeros(UInt8, 40)
    c[2] = zeros(UInt8, 40)
    @test cache_stats(c).currentsize == 80
    c[3] = zeros(UInt8, 40) # needs one eviction
    @test length(c) == 2 && cache_stats(c).currentsize == 80
    c[4] = zeros(UInt8, 90) # needs two evictions
    @test length(c) == 1 && cache_stats(c).currentsize == 90
    c[5] = zeros(UInt8, 101) # larger than the cache: not stored
    @test !haskey(c, 5) && haskey(c, 4)
    @test length(get!(() -> zeros(UInt8, 200), c, 6)) == 200 # still returned
    @test !haskey(c, 6)
end

@testset "$C: recursion and exceptions" for C in CACHETYPES
    c = C{Int, BigInt}(; maxsize = 1000)
    fib(n) = n <= 2 ? big(1) : get!(() -> fib(n - 1) + fib(n - 2), c, n)
    @test fib(200) == big"280571172992510140037611932413038677189525"
    @test_throws ErrorException get!(() -> error("boom"), c, -1)
    @test !haskey(c, -1)
end

@testset "$C: concurrent access" for C in CACHETYPES
    c = C{Int, Int}(; maxsize = 50)
    ok = Threads.Atomic{Bool}(true)
    Threads.@threads for i in 1:10_000
        k = mod(i * 7919, 200)
        get!(() -> 3k, c, k) == 3k || (ok[] = false)
    end
    @test ok[]
    @test length(c) <= 50
    s = cache_stats(c)
    @test s.hits + s.misses == 10_000
    @test all(((k, v),) -> v == 3k, c)
end

@testset "$C: collect while other tasks write" for C in CACHETYPES
    c = C{Int, Int}(; maxsize = 50)
    done = Threads.Atomic{Bool}(false)
    writer = Threads.@spawn while !done[]
        foreach(k -> get!(() -> k, c, k), 1:200)
        empty!(c)
        yield()
    end
    ok = true
    for _ in 1:2_000
        ok &= all(((k, v),) -> k == v, collect(c)) # used to throw when the length changed
        yield()
    end
    done[] = true
    wait(writer)
    @test ok
end

@testset "$C: freed slots release their values" for C in CACHETYPES
    c = C{Int, Base.RefValue{Int}}(; maxsize = 3)
    # build the value inside a function so no local keeps it alive
    weak(c, k) = WeakRef(get!(() -> Ref(k), c, k))
    w = [weak(c, k) for k in 1:3]
    delete!(c, 1) # freed via delete!
    resize!(c; maxsize = 0) # freed via eviction; slots stay on the free list
    GC.gc(true)
    @test isempty(c)
    @test all(r -> r.value === nothing, w)
end

@testset "$C: iteration and display" for C in CACHETYPES
    c = C{Int, Int}(; maxsize = 100)
    for i in 1:10
        c[i] = 2i
    end
    @test sort!(collect(c)) == [i => 2i for i in 1:10]
    @test eltype(collect(c)) == Pair{Int, Int}
    for (k, v) in c # an early break must not leave the cache locked
        break
    end
    @test haskey(c, 1)
    @test sprint(show, c) == "$(C{Int, Int})(10/100 entries, 0 hits, 0 misses)"
    @test startswith(sprint(show, MIME"text/plain"(), c), "$(C{Int, Int})(10/100 entries")
    b = C{Int, Vector{UInt8}}(; maxsize = 100, by = length)
    b[1] = zeros(UInt8, 30)
    @test sprint(show, b) == "$(C{Int, Vector{UInt8}})(1 entries, size 30/100, 0 hits, 0 misses)"

    # iterating while other tasks write sees consistent snapshots
    ok = Threads.Atomic{Bool}(true)
    @sync begin
        Threads.@spawn for i in 1:20_000
            c[mod(i, 300)] = 2 * mod(i, 300)
        end
        Threads.@spawn for _ in 1:200
            ps = collect(c)
            (length(ps) <= 100 && all(((k, v),) -> v == 2k, ps)) || (ok[] = false)
        end
    end
    @test ok[]
end

lookup(c, k) = get!(() -> error("not cached"), c, k)
# measured inside a function: in the loop below the types vary, and a dynamic call boxes its arguments
allocs(c, k) = (lookup(c, k); @allocated lookup(c, k))

@testset "$C: untyped keys" for C in CACHETYPES
    c = C{Any, Any}(; maxsize = 100)
    c[1] = "int"
    c[1.0] = "float" # isequal to 1, but a different type: a different entry
    c[(1,)] = "tuple"
    @test length(c) == 3 && c[1] == "int" && c[1.0] == "float" && c[(1,)] == "tuple"
    delete!(c, 1.0)
    @test !haskey(c, 1.0) && haskey(c, 1)
    # hits do not box the key, neither plain bits nor heap-allocated keys
    bits, heap = (1, 2), ([1, 2], :a)
    c[bits] = 1
    c[heap] = 2
    @test allocs(c, bits) == 0
    @test allocs(c, heap) == 0
end
