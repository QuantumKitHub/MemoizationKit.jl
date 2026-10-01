# Research notes

Ideas and lessons from the first prototype of Cached.jl (March 2026), kept as inspiration for the restart.
None of this is a spec, and the restart is free to throw any of it away.

The prototype code itself lives on the `archive/prototype` branch:

- `c683263` *initial implementation* — one `LRU{Any,Any}` per function, multi-argument and vararg support.
- `3d11e28` *reorganize files* — split into files, one typed `LRU{K,V}` per signature bound to a module-level `const`.
- `0510573` *WIP* — lazy per-concrete-argument-type `LRU{T,V}`, created on first call through `Core.eval`. Does not run as-is.

## Contents

| File | What it covers |
|:-|:-|
| [design.md](design.md) | **The agreed design for the rewrite** |
| [origin.md](origin.md) | Where the design comes from (TensorKit's internal `@cached`) and what the package was meant to fix |
| [architecture.md](architecture.md) | The `CacheStyle` dispatch pattern and the methods the macro generates |
| [global-cache-binding.md](global-cache-binding.md) | How the generated method finds its cache: four approaches tried, with trade-offs |
| [cache-management.md](cache-management.md) | Sizing, preferences, the registry, and introspection |
| [open-questions.md](open-questions.md) | Known bugs, pitfalls, and design questions that were never settled |
