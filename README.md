# MemoizationKit.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://quantumkithub.github.io/MemoizationKit.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://quantumkithub.github.io/MemoizationKit.jl/dev/)
[![Build Status](https://github.com/QuantumKitHub/MemoizationKit.jl/actions/workflows/Tests.yml/badge.svg?branch=main)](https://github.com/QuantumKitHub/MemoizationKit.jl/actions/workflows/Tests.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/QuantumKitHub/MemoizationKit.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/QuantumKitHub/MemoizationKit.jl)
[![Code Style: Runic](https://img.shields.io/badge/code_style-%F0%9F%AA%A8_Runic-9558B2)](https://github.com/fredrikekre/Runic.jl)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

Memoization for Julia, with bounded memory, persistent results, and a live view of your caches.

- **Disk-backed caching:** reuse expensive results across runs with SQLite.jl, or ship precomputed results as artifacts.
- **Live dashboard:** watch hit rates and sizes, browse RAM and disk caches, and clear or resize RAM caches from your terminal.
- **Fast RAM hits:** preserve return-type inference and avoid allocations with the built-in caches and concrete keys.
- **Flexible strategies:** share results across tasks, keep them local to a task, or skip caching for selected argument types.
- **Custom keys:** reuse results for equivalent inputs with `MemoizationKit.cachekey`, or customize hashing and equality with `Hashed`.
- **Bounded storage:** Clock and LRU eviction, with limits in entries or bytes across a function's methods.
- **Package controls:** set defaults per package or function, inspect caches programmatically, and profile lookups and computations with TimerOutputs.jl.

```julia
using MemoizationKit

@cached function fib(n::Int)::BigInt
    n < 2 ? BigInt(n) : fib(n - 1) + fib(n - 2)
end

fib(100)                  # compute and cache
fib(100)                  # reuse the result
cache_info(fib)           # size and hit/miss statistics
set_cache_size!(fib, 1000) # bound the cache
```

## Keep results across runs

Load SQLite.jl and opt a function into disk caching:

```julia
using SQLite
MemoizationKit.DiskCacheStyle(::typeof(fib), ::Int) = DiskCache()
fib(200) # new results are kept in RAM and on disk
```

Calls look in RAM, then on disk, before computing.
Processes on the same machine share the database.
You control result versions and disk cleanup; see [disk caching](https://quantumkithub.github.io/MemoizationKit.jl/dev/disk/).

## See what your caches are doing

Load Tachikoma.jl to browse caches while your program runs:

```julia
using Tachikoma
cache_dashboard()
```

The dashboard shows recent hit rates, storage use, and activity, with separate RAM and Disk tabs:

```text
[RAM] │  Disk
 Name                 Hit rate      Size                   Kind       Activity
 Main.fib             █████60%░░░░░ ▏░░░░░░░3/10k░░░░░░░░░ Clock+disk ███████
 Main.matrix          ████100%█████ ███▊175KiB/1.0MiB░░░░░ Clock      ▆▇█▁▂▃▄▄
 ⇥ tab  ↑↓ select  ⏎ resize  e empty  s sort  / filter  q quit
```

See the [dashboard guide](https://quantumkithub.github.io/MemoizationKit.jl/dev/dashboard/) for controls and statistics.

## Why MemoizationKit?

Choose MemoizationKit when memoization needs ongoing management: memory limits, reuse across runs, or visibility into a running workload.
It brings these tools together with strategies chosen by function and argument type.
For a single in-memory cache, Memoize.jl or Memoization.jl with an LRU container may already cover your needs.
See [the comparison and tradeoffs](https://quantumkithub.github.io/MemoizationKit.jl/dev/#why-memoizationkit).

Requires Julia 1.10 or later.
Start with [usage](https://quantumkithub.github.io/MemoizationKit.jl/dev/#usage), [configuration](https://quantumkithub.github.io/MemoizationKit.jl/dev/configuration/), or [timing](https://quantumkithub.github.io/MemoizationKit.jl/dev/timing/) in the [documentation](https://quantumkithub.github.io/MemoizationKit.jl/dev/).
