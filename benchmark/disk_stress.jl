# Stress test of the disk cache: several processes computing and reading the same entries of
# one function, whose RAM cache is off, so that every call goes to disk. Every value read is
# checked. Run with the test environment, which has SQLite:
#
#   # on one node: NPROCS processes sharing the node's database in DIR
#   julia --project=test benchmark/disk_stress.jl DIR [NPROCS = 4] [NKEYS = 200]
#
#   # on several nodes: start one worker per process (e.g. with your job scheduler); each node
#   # writes its own database file. Then check the files
#   julia --project=test benchmark/disk_stress.jl --worker DIR NKEYS
#   julia --project=test benchmark/disk_stress.jl --check DIR NKEYS
#
# `test/test_disk.jl` includes this file and calls `stress` on a temporary directory.

using Cached
using SQLite: SQLite

const COMPUTED = Ref(0)

# Store the disk caches of this process in `dir`: an environment with the `disk_path`
# preference, added to the load path.
function use_disk_path(dir)
    env = mktempdir()
    write(joinpath(env, "Project.toml"), "[deps]\nCached = \"$(Base.PkgId(Cached).uuid)\"\n")
    write(joinpath(env, "LocalPreferences.toml"), "[Cached]\ndisk_path = $(repr(dir))\n")
    push!(LOAD_PATH, env)
    return env
end

# 0.5 to 4.5 KiB per value, so that some values span several database pages
stress_expected(k) = [sin(k * i) for i in 1:(64 + 37k % 512)]

@cached stress_value(k::Int)::Vector{Float64} = (COMPUTED[] += 1; stress_expected(k))
Cached.CacheStyle(::typeof(stress_value), ::Int) = NoCache()
Cached.DiskCacheStyle(::typeof(stress_value), ::Int) = DiskCache()

# Every key three times, in an order that depends on `seed`.
function stress_worker(dir, nkeys, seed)
    use_disk_path(dir)
    order = sort(1:(3nkeys); by = i -> hash((i, seed)))
    bad = 0
    for i in order
        k = mod1(i, nkeys)
        stress_value(k) == stress_expected(k) || (bad += 1)
    end
    println("RESULT host=$(gethostname()) pid=$(getpid()) calls=$(3nkeys) computed=$(COMPUTED[]) bad=$bad")
    return bad
end

# The database files in `dir`, which must each hold `nkeys` correct entries.
function stress_check(dir, nkeys)
    files = filter(endswith(".sqlite"), readdir(dir))
    bad = 0
    for file in files
        db = SQLite.DB(joinpath(dir, file))
        n = first(SQLite.DBInterface.execute(db, "SELECT count(*) FROM entries"))[1]
        close(db)
        n == nkeys || (bad += 1; println("CHECK $file has $n entries, expected $nkeys"))
    end
    return (; files = length(files), bad)
end

# `nprocs` worker processes on this node, at the same time.
function stress(dir; nprocs = 4, nkeys = 200, project = Base.active_project())
    cmds = [
        `$(Base.julia_cmd()) --startup-file=no -t1 --heap-size-hint=500M --project=$project $(@__FILE__) --worker $dir $nkeys $i`
            for i in 1:nprocs
    ]
    outs = Vector{String}(undef, nprocs)
    errs = [IOBuffer() for _ in 1:nprocs]
    @sync for i in 1:nprocs
        @async outs[i] = read(pipeline(addenv(cmds[i], "JULIA_PKG_OFFLINE" => "true"); stderr = errs[i]), String)
    end
    errs = String.(take!.(errs))
    warnings = count(e -> occursin("Warning", e), errs)
    warnings > 0 && print(stderr, join(errs))
    results = [match(r"computed=(\d+) bad=(\d+)", o) for o in outs]
    any(isnothing, results) && error("a worker failed:\n" * join(outs, "\n"))
    computed = sum(r -> parse(Int, r[1]), results)
    bad = sum(r -> parse(Int, r[2]), results)
    return (; computed, bad, warnings, check = stress_check(dir, nkeys))
end

if abspath(PROGRAM_FILE) == @__FILE__
    if ARGS[1] == "--worker"
        stress_worker(ARGS[2], parse(Int, ARGS[3]), length(ARGS) >= 4 ? parse(Int, ARGS[4]) : getpid())
    elseif ARGS[1] == "--check"
        r = stress_check(ARGS[2], parse(Int, ARGS[3]))
        println("CHECK files=$(r.files) bad=$(r.bad)")
    else
        nprocs = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 4
        nkeys = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 200
        t = @elapsed r = stress(ARGS[1]; nprocs, nkeys)
        println(
            "$nprocs processes, $nkeys keys: computed $(r.computed) times, $(r.bad) bad values, ",
            "$(r.warnings) workers with warnings, $(r.check.files) files with $(r.check.bad) bad, in $(round(t; digits = 1)) s"
        )
    end
end
