using Test
using Cached
using Preferences
using Serialization
using Serialization: AbstractSerializer
using SQLite: SQLite, DBInterface

include(joinpath(pkgdir(Cached), "benchmark", "disk_stress.jl")) # `stress`, `use_disk_path`

const EXT = Base.get_extension(Cached, :CachedSQLiteExt)
const DIR = mktempdir() # the disk caches of this file
const DIR_ENV = use_disk_path(DIR)

allocs(f, x) = (f(x); @allocated f(x)) # in a function, as Julia 1.10 allocates at top level
ram_and_count(f) = (empty_caches!(); before = CALLS[]; r = f(); (r, CALLS[] - before))
const CALLS = Ref(0)
path(f) = only(disk_cache_info(f)).second.path
entries(f) = only(disk_cache_info(f)).second.entries

# a script in a fresh process, with this environment
function run_julia(code)
    cmd = `$(Base.julia_cmd()) --startup-file=no -t1 --heap-size-hint=1G --project=$(Base.active_project()) -e $code`
    return read(addenv(cmd, "JULIA_PKG_OFFLINE" => "true"), String)
end

@cached square(x::Int) = (CALLS[] += 1; [x, x^2])
Cached.DiskCacheStyle(::typeof(square), ::Int) = DiskCache()
plainsquare(x) = square(x)

@testset "RAM, then disk, then compute" begin
    @test Cached.DiskCacheStyle(square, 1) === DiskCache() === DiskCache{Serializer}()
    @test Cached.DiskCacheStyle(sum, 1) === NoCache()
    @test ram_and_count(() -> square(3)) == ([3, 9], 1) # computed, written to disk
    @test square(3) == [3, 9] && CALLS[] == 1 # RAM hit
    @test ram_and_count(() -> square(3)) == ([3, 9], 0) # disk hit
    @test @inferred(square(3)) == [3, 9]
    @test allocs(plainsquare, 3) == 0 # the RAM hit path is unchanged
    info = only(disk_cache_info(square))
    @test info.first === square && info.second.entries == 1 && info.second.bytes > 0
    @test Dict(Cached.disk_cache_stats())[square] == (; hits = 1, misses = 1) # lookups on disk
    @test endswith(EXT.storename(square), ".square-v1") # `<Module>.square-v1`
    @test path(square) == joinpath(DIR, EXT.storename(square) * "-$(EXT._sanitize(gethostname())).sqlite")
end

@cached ondisk(x::Int)::Vector{Int} = (CALLS[] += 1; [x])
Cached.CacheStyle(::typeof(ondisk), ::Int) = NoCache()
Cached.DiskCacheStyle(::typeof(ondisk), ::Int) = DiskCache()

@testset "NoCache in RAM: every call goes to disk" begin
    n = CALLS[]
    @test ondisk(1) == [1] && ondisk(1) == [1] && ondisk(2) == [2]
    @test CALLS[] == n + 2
    @test isempty(cache_info(ondisk))
    @test @inferred(ondisk(1)) == [1]
    @test entries(ondisk) == 2
end

struct Scale
    a::Int
end
@cached (s::Scale)(x::Int) = (CALLS[] += 1; s.a * x)
Cached.DiskCacheStyle(::Scale, ::Int) = DiskCache()

@testset "callable objects are part of the key" begin
    @test ram_and_count(() -> (Scale(2)(3), Scale(3)(3))) == ((6, 9), 2)
    @test ram_and_count(() -> (Scale(2)(3), Scale(3)(3))) == ((6, 9), 0)
    @test entries(Scale(4)) == 2 # one store for the type
end

# A serializer with its own format for `Point`: a string, readable in the database.
mutable struct PointSerializer{I <: IO} <: AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any, Any}
    pending_refs::Vector{Int}
    version::Int
    PointSerializer(io::I) where {I <: IO} = new{I}(io, 0, IdDict(), Int[], 0)
end
struct Point
    x::Int
    y::Int
end
function Serialization.serialize(s::PointSerializer, p::Point)
    Serialization.writetag(s.io, Serialization.OBJECT_TAG)
    serialize(s, Point)
    return serialize(s, "point $(p.x) $(p.y)")
end
function Serialization.deserialize(s::PointSerializer, ::Type{Point})
    _, x, y = split(deserialize(s)::String)
    return Point(parse(Int, x), parse(Int, y))
end

@cached point(x::Int) = (CALLS[] += 1; Point(x, 2x))
Cached.DiskCacheStyle(::typeof(point), ::Int) = DiskCache(; serializer = PointSerializer)

@testset "custom serializer" begin
    @test Cached.DiskCacheStyle(point, 1) === DiskCache{PointSerializer}()
    @test_throws ArgumentError DiskCache{Int}()
    @test ram_and_count(() -> point(4)) == (Point(4, 8), 1)
    @test ram_and_count(() -> point(4)) == (Point(4, 8), 0)
    db = SQLite.DB(path(point))
    value = first(DBInterface.execute(db, "SELECT value FROM entries"))[1]
    close(db)
    @test occursin("point 4 8", String(copy(value)))
end

const VERSION_TAG = Ref("1")
@cached versioned(x::Int) = (CALLS[] += 1; x)
Cached.DiskCacheStyle(::typeof(versioned), ::Int) = DiskCache()
Cached.diskversion(::typeof(versioned)) = VERSION_TAG[]

@testset "a new version invalidates" begin
    @test ram_and_count(() -> versioned(1)) == (1, 1)
    old = path(versioned)
    VERSION_TAG[] = "2"
    EXT.close_all() # as a restart would
    @test ram_and_count(() -> versioned(1)) == (1, 1)
    @test ram_and_count(() -> versioned(1)) == (1, 0)
    @test occursin("-v2-", path(versioned)) && isfile(old) # the old file is left alone
    empty_disk_caches!(versioned)
    @test entries(versioned) == 0
    @test ram_and_count(() -> versioned(1)) == (1, 1)
end

@cached fragile(x::Int)::Vector{Int} = (CALLS[] += 1; [x])
Cached.DiskCacheStyle(::typeof(fragile), ::Int) = DiskCache()

@testset "unreadable entries are recomputed and overwritten" begin
    @test ram_and_count(() -> fragile(1)) == ([1], 1)
    db = SQLite.DB(path(fragile))
    for (column, bad) in (
            "value" => UInt8[0x00, 0xff, 0x13], # garbage
            "value" => let io = IOBuffer() # another type than the value type
                serialize(io, "a string")
                take!(io)
            end,
            "key" => UInt8[0x01], # another key with the same hash
        )
        SQLite.execute(db, "UPDATE entries SET $column = ?1", (bad,))
        @test ram_and_count(() -> fragile(1)) == ([1], 1)
        @test ram_and_count(() -> fragile(1)) == ([1], 0) # the entry was overwritten
    end
    @test entries(fragile) == 1
    close(db)
end

@cached switched(x::Int) = (CALLS[] += 1; x)
Cached.DiskCacheStyle(::typeof(switched), ::Int) = DiskCache()

@testset "turning disk caches off" begin
    disable_disk_caches!()
    try
        @test ram_and_count(() -> switched(1)) == (1, 1)
        @test ram_and_count(() -> switched(1)) == (1, 1)
        @test !any(p -> p.first === switched, disk_cache_info(Main)) # not opened
    finally
        enable_disk_caches!()
    end
    @test ram_and_count(() -> switched(1)) == (1, 1)
    @test ram_and_count(() -> switched(1)) == (1, 0)
end

@cached prefoff(x::Int) = (CALLS[] += 1; x)
@cached prefpath(x::Int) = x
@cached unwritable(x::Int) = (CALLS[] += 1; x)
Cached.DiskCacheStyle(::Union{typeof(prefoff), typeof(prefpath), typeof(unwritable)}, ::Int) = DiskCache()

@testset "preferences, and disk errors" begin
    package = Dict{String, Any}("disk_path" => "/x", "f" => Dict{String, Any}("disk" => false))
    @test Cached._resolve_settings("f", Dict{String, Any}("disk" => true), package)[(:disk, :disk_path)] == (; disk = false, disk_path = "/x")
    @test (@test_logs (:warn, r"invalid preference `disk = 1`") Cached._resolve_settings("f", Dict{String, Any}("disk" => 1), nothing)).disk
    @test_throws ArgumentError set_cache_preferences!(; disk = 1)

    # in a private project, as in `test_preferences.jl`; it comes before `DIR` on the load path
    env = mktempdir()
    write(joinpath(env, "Project.toml"), "[deps]\nCached = \"1b238080-9255-4fe9-b224-89eb24efe93b\"\n")
    old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(env, "Project.toml")
    other = mktempdir()
    try
        set_cache_preferences!(; disk_path = other)
        @test dirname(path(prefpath)) == other

        set_cache_preferences!(; disk_path = joinpath(path(prefpath), "sub")) # under a file
        @test_logs (:warn, r"cannot open the disk cache of `unwritable`") begin # once
            @test ram_and_count(() -> unwritable(1)) == (1, 1)
            @test ram_and_count(() -> unwritable(1)) == (1, 1)
        end

        set_cache_preferences!(; disk = false)
        @test ram_and_count(() -> prefoff(1)) == (1, 1)
        @test ram_and_count(() -> prefoff(1)) == (1, 1)
        @test isempty(disk_cache_info(prefoff))
    finally
        set_cache_preferences!(; disk = nothing, disk_path = nothing)
        Base.ACTIVE_PROJECT[] = old
    end
    @test all(startswith(basename(path(prefpath))), readdir(other)) # and its `-wal`, `-shm`
end

@testset "default directory" begin
    scratch = mktempdir()
    Cached.Scratch.with_scratch_directory(scratch) do
        @test EXT.diskdir(prefpath, "") == joinpath(scratch, string(Base.PkgId(Cached).uuid), "Main")
        # packages get their own scratch space
        @test EXT.diskdir(Preferences.load_preference, "") == joinpath(scratch, string(Base.PkgId(Preferences).uuid), "Cached")
    end
end

module Owned
    using Cached
    @cached a(x::Int) = x
    @cached b(x::Int) = -x
    Cached.DiskCacheStyle(::Union{typeof(a), typeof(b)}, ::Int) = DiskCache()
end

@testset "management per module" begin
    Owned.a(1), Owned.a(2), Owned.b(1)
    info = disk_cache_info(Owned)
    @test Set(first.(info)) == Set([Owned.a, Owned.b]) && sum(p -> p.second.entries, info) == 3
    @test issubset(info, disk_cache_info(Main))
    empty_disk_caches!(Owned)
    @test all(p -> p.second.entries == 0, disk_cache_info(Owned))
end

const ARTIFACT = Ref{Union{Nothing, String}}(nothing)
@cached shipped(x::Int) = (CALLS[] += 1; x + 0.5)
Cached.DiskCacheStyle(::typeof(shipped), ::Int) = DiskCache()
Cached.disk_artifact(::typeof(shipped)) = ARTIFACT[]

@testset "export to a read-only artifact" begin
    @test ram_and_count(() -> (shipped(1), shipped(2))) == ((1.5, 2.5), 2)
    artifact = mktempdir()
    file = export_disk_cache(shipped, artifact)
    @test basename(file) == EXT.storename(shipped) * ".sqlite"
    @test_throws ArgumentError export_disk_cache(shipped, artifact) # exists
    chmod(artifact, 0o555; recursive = true) # read-only, as artifacts are

    # an empty node store, with the artifact in front of it
    empty_disk_caches!(shipped)
    ARTIFACT[] = artifact
    EXT.close_all()
    @test ram_and_count(() -> (shipped(1), shipped(2))) == ((1.5, 2.5), 0)
    @test ram_and_count(() -> shipped(3)) == (3.5, 1) # written to the node store
    @test entries(shipped) == 1
    @test ram_and_count(() -> shipped(3)) == (3.5, 0)
    @test readdir(artifact) == [basename(file)] # no journal or lock files
    EXT.close_all()
    chmod(artifact, 0o755; recursive = true)
end

module Timed
    using Cached
    const LOG = Symbol[]
    @cached f(x::Int) = x
    Cached.DiskCacheStyle(::typeof(f), ::Int) = DiskCache()
    function Cached.instrument(f, ::Val{phase}, thunk, ::Val{fullname(@__MODULE__)}) where {phase}
        push!(LOG, phase)
        return thunk()
    end
end

@testset "the :disk timing phase" begin
    Timed.f(1)
    @test Timed.LOG == [:lookup, :disk, :compute]
    empty!(Timed.LOG), empty_caches!(Timed), Timed.f(1)
    @test Timed.LOG == [:lookup, :disk] # a disk hit
end

@testset "round trip through a fresh process" begin
    dir = mktempdir()
    code = """
    using Cached, SQLite
    include($(repr(joinpath(pkgdir(Cached), "benchmark", "disk_stress.jl"))))
    use_disk_path($(repr(dir)))
    const calls = Ref(0)
    @cached roundtrip(x::Int; scale = 1) = (calls[] += 1; (scale * x, string(x)))
    Cached.DiskCacheStyle(::typeof(roundtrip), ::Int) = DiskCache()
    print(roundtrip(1), roundtrip(2; scale = 3), " calls=", calls[])
    """
    @test run_julia(code) == "(1, \"1\")(6, \"2\") calls=2"
    @test run_julia(code) == "(1, \"1\")(6, \"2\") calls=0"
    # one file: the write-ahead log is merged into the database when the process exits
    @test length(readdir(dir)) == 1
end

@testset "error hint without SQLite" begin
    code = """
    using Cached
    @cached nosqlite(x::Int) = x
    Cached.DiskCacheStyle(::typeof(nosqlite), ::Int) = DiskCache()
    try
        nosqlite(1)
    catch e
        println(e isa MethodError, " ", sprint(showerror, e))
    end
    """
    out = run_julia(code)
    @test startswith(out, "true MethodError")
    @test occursin("`DiskCache` needs SQLite.jl: run `using SQLite` first", out)
end

@testset "processes sharing a database" begin
    nkeys = 100
    r = stress(mktempdir(); nprocs = 4, nkeys)
    @test r.bad == 0 && r.warnings == 0
    @test nkeys <= r.computed < 2nkeys # most values are computed once, but races are allowed
    @test r.check == (; files = 1, bad = 0)
end

EXT.close_all()
filter!(!=(DIR_ENV), LOAD_PATH)
