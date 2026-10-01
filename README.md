# Cached.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://lkdvos.github.io/Cached.jl/dev/)
[![Build Status](https://github.com/lkdvos/Cached.jl/actions/workflows/Tests.yml/badge.svg?branch=main)](https://github.com/lkdvos/Cached.jl/actions/workflows/Tests.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/lkdvos/Cached.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/lkdvos/Cached.jl)
[![Code Style: Runic](https://img.shields.io/badge/code_style-%F0%9F%AA%A8_Runic-9558B2)](https://github.com/fredrikekre/Runic.jl)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

Transparent, strategy-aware memoization for Julia functions.

> [!WARNING]
> This package is under active development and its API may still change.
> The design is described in [`research/design.md`](research/design.md).

```julia
using Cached

@cached function fusion(a, b; normalize = true)
    # expensive computation
end

fusion(1, 2)              # computed
fusion(1, 2)              # looked up in a typed ClockCache{Tuple{Int, Int, @NamedTuple{normalize::Bool}}, V}
uncached(fusion, 1, 2)    # bypasses the cache

# choose the strategy per function and argument type
Cached.CacheStyle(::typeof(fusion), a::Int, b::Int) = TaskLocalCache{LRU}()

cache_info(fusion)        # hit/miss statistics
set_cache_size!(fusion, 1_000)
```
