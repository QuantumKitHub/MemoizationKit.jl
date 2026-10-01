using Test
using Cached
using Preferences
using Aqua: Aqua

const resolve = Cached._resolve_settings

@testset "resolution order" begin
    @test resolve("f", Dict(), nothing) == (; maxsize = 10_000, by = nothing, maxsubcaches = 100)
    cached = Dict{String, Any}("maxsize" => 500, "maxsubcaches" => 7)
    @test resolve("f", cached, nothing) == (; maxsize = 500, by = nothing, maxsubcaches = 7)
    package = Dict{String, Any}("maxsize" => 50, "measure" => "bytes", "g" => Dict{String, Any}("maxsize" => 5))
    @test resolve("f", cached, package) == (; maxsize = 50, by = Base.summarysize, maxsubcaches = 7)
    @test resolve("g", cached, package) == (; maxsize = 5, by = Base.summarysize, maxsubcaches = 7)
end

@testset "invalid preferences are ignored with a warning" begin
    for (section, msg) in (
            Dict{String, Any}("maxsise" => 1) => r"unknown preference `maxsise`",
            Dict{String, Any}("maxsize" => -1) => r"invalid preference `maxsize = -1`",
            Dict{String, Any}("maxsize" => true) => r"invalid preference `maxsize = true`",
            Dict{String, Any}("maxsubcaches" => 0) => r"invalid preference `maxsubcaches = 0`",
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

# Preferences are written next to the active project; remove the file afterwards if the
# tests created it.
const prefsfile = joinpath(dirname(Base.active_project()), "LocalPreferences.toml")
const hadprefsfile = isfile(prefsfile)

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
hadprefsfile || rm(prefsfile; force = true)

@testset "container preference (compile time)" begin
    @test Cached.DEFAULT_CONTAINER === ClockCache
    @test CacheStyle(sum, 1) === GlobalCache{ClockCache}()

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
        print(Cached.CacheStyle(sum, 1) === GlobalCache{LRU}())
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no -e $code`,
            "JULIA_PKG_OFFLINE" => "true", "JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PROJECT" => nothing,
        )
        @test readchomp(cmd) == "true"
    end
end
