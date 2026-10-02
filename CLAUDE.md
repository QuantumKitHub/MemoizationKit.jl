# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout

This checkout is the `main` worktree of a bare repository: `../Cached.jl` is the bare git dir and
sibling directories of `main/` are other worktrees. Create new worktrees next to `main/`
(`git worktree add ../<name> -b <branch>`), never inside it.

## Commands

No `Manifest.toml` is checked in (it is gitignored), so instantiate first:

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
```

```bash
# Run all tests (ParallelTestRunner picks up every test/*.jl except runtests.jl)
julia --project -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project=test test/test_aqua.jl

# Build docs
julia --project=docs docs/make.jl

# Format (Runic). Not a project dependency; CI checks it through a reusable workflow.
julia --project=/tmp/runic -e 'using Pkg; Pkg.add("Runic"); using Runic; Runic.main(["--inplace", "src", "ext", "test", "docs"])'
```

## Architecture

`research/design.md` is the spec; the other notes in `research/` describe the archived prototype
(branch `archive/prototype`) and are background only.

- `src/macro.jl`: `@cached` moves the body to a method of `Cached.implementation(::typeof(f), ...)`
  and leaves `f` with its original signature, calling `Cached.call`. ExprTools does the parsing.
- `src/call.jl`: `call` picks the value type `V` (annotation, or `return_type`) and dispatches on
  the `CacheStyle` (`NoCache`, `GlobalCache{C}`, `TaskLocalCache{C}`). The lookup and the
  implementation call are wrapped in the internal `instrument(f, Val(phase), thunk, owner)` hook,
  with `owner` the package owning `f` (or its module, outside packages); its default `thunk()` compiles away.
- `src/registry.jl`: global caches, one untyped `C{Any,Any}` per function (its budget), looked up
  lock-free in an atomically published `IdDict` snapshot.
- `src/containers/`: `LRU` and `ClockCache`, sharing the `AbstractCache` interface. Keys are
  stored as `Key{Any}` (or `Any` plus hash) and probed with a concretely typed `Key{K}`, so hits
  never box. `LRU` takes its lock for every operation; `ClockCache` (`clock.jl`) has lock-free
  hits, through an atomically published open-addressing table of immutable entries, and keeps
  the three invariants listed in its source (`research/lockfree-clock.md`). Task-local caches
  use `LocalClockCache` (`localclock.jl`), the locked `ClockCache`, via `_localtype` in `call.jl`.
- `src/preferences.jl`: default settings from Preferences.jl, resolved once per function
  (runtime > function > package > `[Cached]` > built-in), and `set_cache_preferences!`.
- `src/api.jl`: `cache_info`, `empty_caches!`, `set_cache_size!`, and the `cache_dashboard` and
  `enable_cache_timers!`/`disable_cache_timers!` stubs with their error hints (registered in `__init__`).
- `ext/CachedTachikomaExt.jl`: the dashboard. It renders from a copy of the statistics, refreshed
  every `interval`; tests render it headlessly with Tachikoma's `TestBackend`.
- `ext/CachedTimerOutputsExt.jl`: `enable_cache_timers!(M)` evals a method of `instrument` for
  the owner of `M` into the extension, `disable_cache_timers!(M)` deletes it (deleting an
  overwritten method would revive the old one, so enabling deletes before defining).

Hot-path invariants, checked by the tests: a cache hit is fully inferred and allocates nothing.
Benchmark with `julia --project=benchmark -t 8 benchmark/containers.jl`.
