# Cost of a lookup when all threads share one cache, against task-local caches.
# "locked Clock" is the `ClockCache` of task-local caches (`Cached.LocalClockCache`), whose hits
# take the lock, shared here for comparison.
#
#     for t in 1 2 4 8; do julia --heap-size-hint=4G --project=benchmark -t $t benchmark/contention.jl; done
#
# One task per thread, each doing `M` lookups from its own key sequence. Reports the median over
# `REPS` runs of the time per lookup within a task (ns/lookup, lower is better; perfect scaling
# keeps it constant as threads are added), and the bytes allocated per lookup.

using Random, Printf, Statistics
using Cached: Cached, ClockCache, LocalClockCache, LRU, @cached, GlobalCache, TaskLocalCache

const M = 200_000
const REPS = 7

const CONTAINERS = [
    "ClockCache" => n -> ClockCache{Any, Any}(; maxsize = n),
    "locked Clock" => n -> LocalClockCache{Any, Any}(; maxsize = n),
    "LRU" => n -> LRU{Any, Any}(; maxsize = n),
    "task-local Clock" => nothing, # one locked Clock per task, uncontended
]

function zipf(rng, n, s, len)
    cdf = cumsum(1 ./ (1:n) .^ s)
    cdf ./= cdf[end]
    return [searchsortedfirst(cdf, rand(rng)) for _ in 1:len]
end

tuplekey(i) = (i, i % 7, :leg, Float64(i))
compute(k::Int) = 3k
compute(k::Tuple) = k[1]

# name => (key sequence per task, cache capacity, prefill keys)
function workloads(ntasks)
    rngs = [Xoshiro(t) for t in 1:ntasks]
    return [
        "hits, Int keys (1k)" => ([rand(r, 1:1_000, M) for r in rngs], 10_000, 1:1_000),
        "hits, 4-tuple keys (1k)" => ([tuplekey.(rand(r, 1:1_000, M)) for r in rngs], 10_000, tuplekey.(1:1_000)),
        "hits, one hot Int key" => ([fill(7, M) for r in rngs], 10_000, 7:7),
        "zipf 1.0 (100k keys, cap 10k)" => ([zipf(r, 100_000, 1.0, M) for r in rngs], 10_000, 1:0),
        "uniform (20k keys, cap 10k)" => ([rand(r, 1:20_000, M) for r in rngs], 10_000, 1:0),
    ]
end

function run!(c, seq)
    acc = 0
    for k in seq
        acc += get!(() -> compute(k), c, k)::Int
    end
    return acc
end

# ns per lookup in each task, and total bytes allocated
function threaded(make, seqs, cap, prefill)
    shared = make === nothing ? nothing : make(cap)
    caches = [shared === nothing ? LocalClockCache{Any, Any}(; maxsize = cap) : shared for _ in seqs]
    for c in unique(caches), k in prefill
        get!(() -> compute(k), c, k)
    end
    times = zeros(length(seqs))
    start = Threads.Atomic{Int}(0)
    bytes = @allocated @sync for (t, seq) in enumerate(seqs)
        Threads.@spawn begin
            Threads.atomic_add!(start, 1)
            while start[] < length(seqs) # start together
                ccall(:jl_cpu_pause, Cvoid, ())
            end
            t0 = time_ns()
            run!(caches[t], seq)
            times[t] = (time_ns() - t0) / length(seq)
        end
    end
    return mean(times), bytes / sum(length, seqs)
end

# ns per hit through `@cached` functions using each cache style, Int and 4-tuple keys
@cached f_clock(x) = compute(x)
@cached f_locked(x) = compute(x)
@cached f_lru(x) = compute(x)
@cached f_local(x) = compute(x)
Cached.CacheStyle(::typeof(f_clock), x) = GlobalCache{ClockCache}()
Cached.CacheStyle(::typeof(f_locked), x) = GlobalCache{LocalClockCache}()
Cached.CacheStyle(::typeof(f_lru), x) = GlobalCache{LRU}()
Cached.CacheStyle(::typeof(f_local), x) = TaskLocalCache{ClockCache}()
const CACHED = ["ClockCache" => f_clock, "locked Clock" => f_locked, "LRU" => f_lru, "task-local Clock" => f_local]

function callall(f::F, seq) where {F}
    acc = 0
    for k in seq
        acc += f(k)::Int
    end
    return acc
end

function threaded_cached(f, seqs, keys)
    times = zeros(length(seqs))
    bytes = @allocated @sync for (t, seq) in enumerate(seqs)
        Threads.@spawn begin
            callall(f, keys) # fill this task's cache (task-local)
            t0 = time_ns()
            callall(f, seq)
            times[t] = (time_ns() - t0) / length(seq)
        end
    end
    return mean(times), bytes / sum(length, seqs)
end

nt = Threads.nthreads()
println("Julia ", VERSION, ", ", nt, " threads (", nt, " tasks), ", M, " lookups per task, median of ", REPS, " runs")
println("load average: ", read(`cat /proc/loadavg`, String))
@printf("%-30s %-17s %10s %10s %8s\n", "workload", "container", "ns/lookup", "(min)", "B/lookup")
for (wname, (seqs, cap, prefill)) in workloads(nt)
    for (cname, make) in CONTAINERS
        threaded(make, seqs, cap, prefill) # compile
        rs = [threaded(make, seqs, cap, prefill) for _ in 1:REPS]
        @printf(
            "%-30s %-17s %10.1f %10.1f %8.2f\n", wname, cname,
            median(first.(rs)), minimum(first.(rs)), median(last.(rs))
        )
    end
end
for (kname, keys) in ("@cached hits, Int" => 1:1_000, "@cached hits, 4-tuple" => tuplekey.(1:1_000))
    seqs = [rand(Xoshiro(t), keys, M) for t in 1:nt]
    for (cname, f) in CACHED
        foreach(f, keys)
        threaded_cached(f, seqs, keys)
        rs = [threaded_cached(f, seqs, keys) for _ in 1:REPS]
        @printf(
            "%-30s %-17s %10.1f %10.1f %8.2f\n", kname, cname,
            median(first.(rs)), minimum(first.(rs)), median(last.(rs))
        )
    end
end
