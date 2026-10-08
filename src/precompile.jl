# Keep the example functions private and separate from the public API.
module _Precompile

using ..MemoizationKit
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    struct Workload{S, D}
        offset::Int
    end

    MemoizationKit.CacheStyle(::Workload{S}, args...) where {S} = S()
    MemoizationKit.DiskCacheStyle(::Workload{S, D}, args...) where {S, D} = D()

    @cached (f::Workload)(x) = f.offset + x
    @cached (f::Workload)(x, rest...; scale = 1)::Int = scale * (f.offset + x + length(rest))
    @cached basic(x) = x
    @cached unstable(x) = x > 0 ? x : "negative"
    @cached keyed(x) = length(x)
    MemoizationKit.cachekey(::typeof(keyed), x) = (Hashed(x),)

    let
        # Preserve task-local state, and remove only this workload's registry entries.
        tls = task_local_storage()
        had_local = haskey(tls, :__MemoizationKit_tasklocal__)
        old_local = get(tls, :__MemoizationKit_tasklocal__, nothing)
        tls[:__MemoizationKit_tasklocal__] = IdDict{Any, Any}()
        io = IOBuffer()
        try
            @compile_workload begin
                # Compile the macro itself as well as the wrappers generated above.
                for ex in (
                        :(@cached example(x) = x),
                        :(
                            @cached function example(x::T, y = 1, rest...; scale = 1, kw...)::T where {T}
                                return x
                            end
                        ),
                        :(@cached (::Workload)(::Int) = 1),
                    )
                    macroexpand(@__MODULE__, ex)
                end

                for S in (GlobalCache{ClockCache}, GlobalCache{LRU}, TaskLocalCache{ClockCache}, TaskLocalCache{LRU}, TaskLocalCache{Dict}, NoCache)
                    # Disk calls compile their RAM/compute fallback without touching files.
                    for D in (NoCache, DiskCache{MemoizationKit.Serializer})
                        f = Workload{S, D}(1)
                        set_cache_size!(f, 2)
                        for x in (1, 2, 3, 3)
                            f(x)
                            f(x, 2; scale = 2)
                        end
                        f(1.0)
                        uncached(f, 1)
                        uncached(f, 1, 2; scale = 2)
                        MemoizationKit.instrument_label(f, Val(:lookup))
                        cache_info(f)
                        set_cache_size!(f, 1)
                        empty_caches!(f)
                        set_cache_size!(f, 32; by = MemoizationKit.cachesize)
                        f(1)
                    end
                end

                basic(1)
                basic(1)
                unstable(1)
                unstable(-1)
                keyed([1, 2])
                keyed([1, 2])
                cache_info()
                cache_info(@__MODULE__)
                empty_caches!(@__MODULE__)

                # Exercise both eviction policies and the shared dictionary interface,
                # including typed/untyped storage and byte-based size accounting.
                for C in (LRU, ClockCache)
                    for c in (C{Any, Any}(; maxsize = 2), C{Int, Int}(; maxsize = 2), C{Int, Int}(; maxsize = 16, by = MemoizationKit.cachesize))
                        for x in (1, 2, 3, 3)
                            get!(Returns(x), c, x)
                        end
                        c[3]
                        c[3] = 4
                        get(c, 0, nothing)
                        haskey(c, 3)
                        length(c)
                        isempty(c)
                        collect(c)
                        MemoizationKit.cache_stats(c)
                        show(io, c)
                        show(io, MIME"text/plain"(), c)
                        delete!(c, 3)
                        c[4] = 4
                        resize!(c; maxsize = 0)
                        empty!(c)
                    end
                end
            end
        finally
            had_local ? (tls[:__MemoizationKit_tasklocal__] = old_local) : pop!(tls, :__MemoizationKit_tasklocal__, nothing)
            # Emptying a cache alone keeps its registration and size settings alive.
            Base.@lock MemoizationKit.REGISTRY.lock begin
                for f in collect(keys(MemoizationKit.REGISTRY.functions))
                    parentmodule(typeof(f)) === (@__MODULE__) && delete!(MemoizationKit.REGISTRY.functions, f)
                end
                MemoizationKit._publish!()
            end
        end
    end
end

end # module _Precompile
