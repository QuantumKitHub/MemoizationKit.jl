using Test
using Cached
using SQLite: SQLite

include(joinpath(pkgdir(Cached), "benchmark", "disk_stress.jl"))

const EXT = Base.get_extension(Cached, :CachedSQLiteExt)
const DIR_ENV = use_disk_path(mktempdir())
const CALLS = Ref(0)
counted(x) = (CALLS[] += 1; x)
entries(f) = only(disk_cache_info(f)).second.entries

@cached canonical(x::AbstractVector) = counted(length(x))
@cached canonical(x::Tuple) = counted(length(x))
Cached.cachekey(::typeof(canonical), x) = length(x)
Cached.DiskCacheStyle(::typeof(canonical), x) = DiskCache()

lengthhash(x, seed) = hash(length(x), seed)
lengthequal(x, y) = isequal(length(x), length(y))
@cached wrapped(x) = counted(length(x))
Cached.cachekey(::typeof(wrapped), x) = Hashed(x, lengthhash, lengthequal)
Cached.DiskCacheStyle(::typeof(wrapped), x) = DiskCache()

try
    @testset "canonical keys on disk" begin
        @test canonical([1, 2]) == 2
        empty_caches!(canonical)
        @test @inferred(canonical((3, 4))) == 2 # disk hit across methods
        @test CALLS[] == 1
        @test entries(canonical) == 1
        @test canonical((1, 2, 3)) == 3
        @test CALLS[] == 2
        @test entries(canonical) == 2
    end

    @testset "wrapper equality on RAM, bytes on disk" begin
        n = CALLS[]
        @test wrapped([1, 2]) == 2
        @test wrapped([3, 4]) == 2 # RAM hit
        @test CALLS[] == n + 1
        empty_caches!(wrapped)
        @test wrapped([3, 4]) == 2 # different serialized key: disk miss
        @test CALLS[] == n + 2
        @test entries(wrapped) == 2
        empty_caches!(wrapped)
        @test wrapped([1, 2]) == 2 # original serialized key: disk hit
        @test CALLS[] == n + 2
    end
finally
    EXT.close_all()
    filter!(!=(DIR_ENV), LOAD_PATH)
end
