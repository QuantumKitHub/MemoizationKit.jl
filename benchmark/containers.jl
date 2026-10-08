# Compare the cache containers on synthetic access patterns.
#
#     julia --project=benchmark -t 8 benchmark/containers.jl
#
# Reports nanoseconds per `get!` (single-threaded), hit rates, and multithreaded throughput.
# The value computation is trivial, so the numbers measure cache overhead only.

using BenchmarkTools, Random, Printf
using MemoizationKit: MemoizationKit
using LRUCache: LRUCache

const CONTAINERS = [
    "MemoizationKit.LRU" => (K, V, n) -> MemoizationKit.LRU{K, V}(; maxsize = n),
    "MemoizationKit.ClockCache" => (K, V, n) -> MemoizationKit.ClockCache{K, V}(; maxsize = n),
    "LRUCache.LRU" => (K, V, n) -> LRUCache.LRU{K, V}(; maxsize = n),
]

# Zipf(s) samples over 1:n via inverse CDF.
function zipf(rng, n, s, len)
    cdf = cumsum(1 ./ (1:n) .^ s)
    cdf ./= cdf[end]
    return [searchsortedfirst(cdf, rand(rng)) for _ in 1:len]
end

function run!(c, seq)
    acc = 0
    for k in seq
        acc += get!(() -> 3k, c, k)
    end
    return acc
end

hitrate(c::LRUCache.LRU) = (i = LRUCache.cache_info(c); i.hits / (i.hits + i.misses))
hitrate(c) = (s = MemoizationKit.cache_stats(c); s.hits / (s.hits + s.misses))

function threaded!(c, seq, ntasks)
    chunks = Iterators.partition(seq, cld(length(seq), ntasks))
    tasks = [Threads.@spawn run!(c, chunk) for chunk in chunks]
    return sum(fetch, tasks)
end

rng = Xoshiro(42)
const N = 10^6
workloads = [
    "all hits (1k keys, cap 10k)" => (rand(rng, 1:1_000, N), 10_000),
    "zipf 1.0 (100k keys, cap 10k)" => (zipf(rng, 100_000, 1.0, N), 10_000),
    "zipf 0.8 (100k keys, cap 10k)" => (zipf(rng, 100_000, 0.8, N), 10_000),
    "uniform (100k keys, cap 10k)" => (rand(rng, 1:100_000, N), 10_000),
]

nt = Threads.nthreads()
println("Julia ", VERSION, ", ", nt, " threads, ", N, " lookups per workload\n")
for (wname, (seq, cap)) in workloads
    println(wname)
    for (cname, make) in CONTAINERS
        c = make(Int, Int, cap)
        run!(c, seq) # warm up: compile and reach steady state
        t1 = @belapsed run!($c, $seq) samples = 5 evals = 1
        c = make(Int, Int, cap)
        run!(c, seq)
        hr = hitrate(c)
        tn = nt > 1 ? (@belapsed threaded!($c, $seq, $nt) samples = 5 evals = 1) : NaN
        @printf(
            "  %-18s %6.1f ns/op   hit rate %5.1f%%   %d threads: %6.1f ns/op\n",
            cname, 1.0e9 * t1 / N, 100 * hr, nt, 1.0e9 * tn / N
        )
    end
    println()
end
