macro cached(ex)
    (; fname, params, typeex, typed, raw_args, fbody) = splitdef(ex)

    # Reject features that are not supported
    (!isempty(raw_args) && Meta.isexpr(raw_args[1], :parameters)) &&
        throw(ArgumentError("@cached does not support keyword arguments"))
    for arg in raw_args
        Meta.isexpr(arg, :kw) &&
            throw(ArgumentError("@cached does not support default argument values"))
    end

    cache_var = gensym("cache")
    type_var = gensym("T")

    cached_f = quote
        function $fname(::GlobalLRUCache, arg::$(Symbol("$type_var"))) where {$params...}
            val::$(typed ? typeex : :Any) = get!($(Symbol("$cache_var")), arg) do
                return $fname(NoCache(), $arg)
            end
            return val
        end
    end


    default_f = quote
        # fallback definition that creates the specialized method and inserts the cache
        function $fname(strategy::GlobalLRUCache, arg)
            # create a cache and register it
            T = typeof(arg)
            $cache_var = LRU{T, $(typed ? typeex : :Any)}()
            method_caches[($fname, T)] = $cache_var

            # redefine more concrete signature and immediately call it
            @eval $cached_f
            return Base.invokelatest($fname, strategy, arg)
        end
    end

    return esc(default_f)
end
