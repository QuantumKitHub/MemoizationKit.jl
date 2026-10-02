using Test
using Cached
using Preferences
using Aqua: Aqua

const resolve = Cached._resolve_settings
caches(f) = last.(cache_info(f))

@testset "resolution order" begin
    @test resolve("f", Dict(), nothing) == (; maxsize = 10_000, by = nothing)
    cached = Dict{String, Any}("maxsize" => 500)
    @test resolve("f", cached, nothing) == (; maxsize = 500, by = nothing)
    package = Dict{String, Any}("maxsize" => 50, "measure" => "bytes", "g" => Dict{String, Any}("maxsize" => 5))
    @test resolve("f", cached, package) == (; maxsize = 50, by = Cached.cachesize)
    @test resolve("g", cached, package) == (; maxsize = 5, by = Cached.cachesize)
end

@testset "invalid preferences are ignored with a warning" begin
    for (section, msg) in (
            Dict{String, Any}("maxsise" => 1) => r"unknown preference `maxsise`",
            Dict{String, Any}("maxsize" => -1) => r"invalid preference `maxsize = -1`",
            Dict{String, Any}("maxsize" => true) => r"invalid preference `maxsize = true`",
            Dict{String, Any}("maxsubcaches" => 2) => r"unknown preference `maxsubcaches`", # removed setting
            Dict{String, Any}("measure" => "kilos") => r"invalid preference `measure = \"kilos\"`",
        )
        s = @test_logs (:warn, msg) resolve("f", section, nothing)
        @test s == resolve("f", Dict(), nothing)
    end
end

struct Key
    x::Int
end

# preferences are read on the first call, not at definition
@cached fromcached(x) = x
@cached Aqua.test_all(k::Key) = k.x
@cached Aqua.test_ambiguities(k::Key) = k.x

# Preferences are written next to the active project. Point it at a private temporary project
# while writing them, so that test files running in parallel never see them.
function with_private_preferences(f)
    env = mktempdir()
    write(
        joinpath(env, "Project.toml"),
        """
        [deps]
        Aqua = "4c88cf16-eb10-579e-8560-4a9242c79595"
        Cached = "1b238080-9255-4fe9-b224-89eb24efe93b"
        """
    )
    old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(env, "Project.toml")
    try
        return f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

with_private_preferences() do
    @testset "preferences are read when a function's first cache is created" begin
        # Cached's own section
        set_preferences!(Cached, "maxsize" => 7, "measure" => "count"; force = true)
        try
            fromcached(1)
            @test only(cache_info(fromcached)).second.maxsize == 7
        finally
            delete_preferences!(Cached, "maxsize", "measure"; force = true)
        end

        # the section of the package that owns the function (here Aqua), and per-function sections
        set_preferences!(
            Aqua, "Cached" => Dict("maxsize" => 3, "test_ambiguities" => Dict("maxsize" => 2));
            force = true
        )
        try
            Aqua.test_all(Key(1))
            Aqua.test_ambiguities(Key(1))
            @test only(cache_info(Aqua.test_all)).second.maxsize == 3
            @test only(cache_info(Aqua.test_ambiguities)).second.maxsize == 2
            # runtime settings still override preferences
            set_cache_size!(Aqua.test_all, 11)
            @test only(cache_info(Aqua.test_all)).second.maxsize == 11
        finally
            delete_preferences!(Aqua, "Cached"; force = true)
        end

        # functions outside packages only see Cached's section
        @test Cached._package_section(fromcached) === nothing
    end
end
with_private_preferences() do
    @testset "set_cache_preferences!" begin
        try
            # global section, including the compile-time container
            set_cache_preferences!(; maxsize = 123, container = "LRU")
            @test load_preference(Cached, "maxsize") == 123
            @test load_preference(Cached, "container") == "LRU"
            set_cache_preferences!(; maxsize = nothing, container = nothing)
            @test !has_preference(Cached, "maxsize") && !has_preference(Cached, "container")

            # package and function sections combine without clobbering each other
            set_cache_preferences!(Aqua.test_all; maxsize = 4)
            set_cache_preferences!(Aqua; measure = "bytes")
            set_cache_preferences!(Aqua.test_ambiguities; measure = "count")
            section = load_preference(Aqua, "Cached")
            @test section == Dict(
                "measure" => "bytes", "test_all" => Dict("maxsize" => 4),
                "test_ambiguities" => Dict("measure" => "count")
            )
            @test Cached._resolve_settings("test_all", Dict(), section) ==
                (; maxsize = 4, by = Cached.cachesize)
            set_cache_preferences!(Aqua.test_all; maxsize = nothing) # empty sections are removed
            @test !haskey(load_preference(Aqua, "Cached"), "test_all")

            @test_throws ArgumentError set_cache_preferences!(Aqua; maxsize = -1)
            @test_throws ArgumentError set_cache_preferences!(Aqua; measure = "kilos")
            @test_throws ArgumentError set_cache_preferences!(Aqua; container = "LRU") # global only
            @test_throws ArgumentError set_cache_preferences!(Aqua; maxsise = 1)
            @test_throws ArgumentError set_cache_preferences!(x -> x; maxsize = 1) # not in a package
        finally
            delete_preferences!(Aqua, "Cached"; force = true)
            delete_preferences!(Cached, "maxsize", "container"; force = true)
        end
    end
end

struct Blob
    data::Vector{UInt8}
    meta::Vector{Int}
end
Cached.cachesize(b::Blob) = length(b.data)

@cached blob(n::Int) = Blob(zeros(UInt8, n), collect(1:1000))

@testset "cachesize can be overloaded" begin
    @test Cached.cachesize([1, 2, 3]) == Base.summarysize([1, 2, 3])
    set_cache_size!(blob, 100; by = Cached.cachesize)
    blob(40)
    blob(50)
    c = only(caches(blob))
    @test Cached.cache_stats(c).currentsize == 90 # ignores `meta`, unlike summarysize
    blob(20) # evicts one entry to fit
    @test length(c) == 2
end


@testset "container preference (compile time)" begin
    @test Cached.DEFAULT_CONTAINER === ClockCache
    @test CacheStyle(sum, 1) === GlobalCache{ClockCache}() === GlobalCache()
    @test TaskLocalCache() === TaskLocalCache{ClockCache}()

    # a fresh process with `container = "LRU"` in Cached's preferences
    mktempdir() do env
        write(
            joinpath(env, "LocalPreferences.toml"),
            "[Cached]\ncontainer = \"LRU\"\n"
        )
        code = """
        using Pkg
        Pkg.activate($(repr(env)); io = devnull)
        Pkg.develop(path = $(repr(pkgdir(Cached))); io = devnull)
        using Cached
        print(Cached.CacheStyle(sum, 1) === GlobalCache() === GlobalCache{LRU}())
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no -e $code`,
            "JULIA_PKG_OFFLINE" => "true", "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ";" : ":"), "JULIA_PROJECT" => nothing,
        )
        @test readchomp(cmd) == "true"
    end
end
