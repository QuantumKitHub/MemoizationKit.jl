# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests
julia --project -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project test/runtests.jl

# Start Julia REPL with project active
julia --project
```

## Architecture

Cached.jl is a single-file Julia package (`src/Cached.jl`, ~800 lines) providing transparent function memoization via macros.

### Cache Strategy Dispatch

The core pattern: `@cached` transforms `f(args...)` into four methods:

1. **Dispatch wrapper** — `f(args...)` calls `f(CacheStyle(f, args...), args...)` to select strategy
2. **NoCache impl** — `f(::NoCache, args...)` contains the actual user code
3. **TaskLocal method** — `f(::TaskLocalCache{D}, args...)` looks up in `task_local_storage()`
4. **GlobalLRU method** — `f(::GlobalLRUCache, args...)` checks a module-level `const` LRU

Users can override cache strategy for specific argument types by defining `CacheStyle(::typeof(f), ::SpecialType) = NoCache()`.

### Two Macros

- **`@cached`** — precompilation-safe; binds the LRU via a module-level `const` (compiler resolves to direct pointer)
- **`@cached_direct`** — REPL/script only; embeds LRU via `Core.eval` (true closure, not safe for precompilation)

### Cache Registry

- `PER_SIG_CACHES` — maps signature strings → LRU objects (enables `global_cache_info()`)
- `_FUNC_TO_SIG_KEYS` — maps function → [signature keys] (for `empty_globalcaches!(f)`)
- Each unique `(function, arg_types)` signature gets its own `LRU{K,V}`, where `K` and `V` are inferred at macro expansion time

### Key Constraints

- Each `(function, signature)` pair can only be `@cached` once — duplicate registration is an error
- No keyword arguments or default argument values in cached functions
- Return type annotation is optional but required when Julia cannot infer `V`

### LRU Type Inference

The macros infer `LRU{K,V}` types at expansion time:
- `K` — `Tuple{arg_types...}` for multi-arg, bare type for single-arg
- `V` — from return type annotation, or `Any` if unannotated

### Configuration

Cache sizes are configurable via `LocalPreferences.toml` and the runtime API:
- `set_cache_size!(f, n)` — count-based limit
- `set_cache_bytesize!(f, bytes)` — byte-based limit (uses `Base.summarysize` by default)
- Default: 64 GiB byte-based or 10,000 entries count-based
