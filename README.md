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
fusion(1, 2)              # looked up in fusion's cache; the result is still inferred
uncached(fusion, 1, 2)    # bypasses the cache

# choose the strategy per function and argument type
Cached.CacheStyle(::typeof(fusion), a::Int, b::Int) = TaskLocalCache{LRU}()

cache_info(fusion)        # hit/miss statistics
set_cache_size!(fusion, 1_000)
```

Default sizes can be configured per package and per function through `LocalPreferences.toml`; see the [configuration docs](https://lkdvos.github.io/Cached.jl/dev/configuration/).

With [TimerOutputs.jl](https://github.com/KristofferC/TimerOutputs.jl) loaded, `enable_cache_timers!(MyPackage, to)` times the lookups and computations of the cached functions owned by `MyPackage` and its submodules, and `disable_cache_timers!(MyPackage)` brings back the zero-cost default. See the [timing docs](https://lkdvos.github.io/Cached.jl/dev/timing/).

With [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) loaded, `cache_dashboard()` opens a live terminal dashboard to browse, empty and resize the caches; see the [dashboard docs](https://lkdvos.github.io/Cached.jl/dev/dashboard/).

```text
 4 caches, 383 entries
 Name ▲               Hit rate      Size                   Kind  Activity
 Main.fib             █████67%▋░░░░ ▏░░░░░░░61/10k░░░░░░░░ LRU   ████████
▌Main.fsymbol         █████67%▊░░░░ ▋░░░░░░276/10k░░░░░░░░ Clock ▄█▆▃▇▅▂▆
 Main.label           ████100%█████ ▏░░░░░░░6/10k░░░░░░░░░ Clock ▇█ ▁▃▄▅▇
 Main.matrix          ████100%█████ ███▊175KiB/1.0MiB░░░░░ Clock ▆▇█▁▂▃▄▄
 ↑↓ select  ⏎ resize  e empty  s sort  r reverse  / filter  g refresh  q quit
```
