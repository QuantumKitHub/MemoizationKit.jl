# Repository guidance

## Layout

This repository uses sibling worktrees with the bare Git repository at `../Cached.jl`.
Create additional worktrees beside the current checkout, never inside it.

- `src/`: memoization macro, strategy dispatch, cache containers, registry, and configuration.
- `ext/`: optional SQLite persistence, Tachikoma dashboard, and TimerOutputs integration.
- `test/`: tests discovered by ParallelTestRunner.
- `docs/src/`: user guides and API reference.
- `benchmark/`: cache container and disk benchmarks.

See `docs/src/index.md` for behavior and `docs/src/interface.md` for the custom cache contract.

## Development

Manifests are ignored; instantiate the environment before running tests or building docs.

```bash
# Install dependencies and run tests
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

# Run a single test file
julia --project=test test/test_macro.jl

# Prepare and build documentation
julia --project=docs -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --project=docs docs/make.jl

# Benchmark containers
julia --project=benchmark -t 8 benchmark/containers.jl
```

Format Julia files with Runic; CI checks formatting.
Keep Markdown prose to one sentence per line.

## Implementation constraints

- `@cached` preserves the method signature and moves the body to `Cached.implementation`.
- The default global cache shares one size limit across a function's cached methods, with a separate cache per container type.
- Preserve inferred return types and allocation-free RAM hits for concrete keys with the built-in containers.
- Built-in RAM containers distinguish key types and use `hash` and `isequal`.
- `Cached.cachekey` may merge equivalent inputs; merged calls must accept the same result and return type.
- Compute misses outside cache locks so recursion works; concurrent misses may compute twice.
- Keep the call path safe for precompiled packages, without runtime method definitions.
- Disk lookup order is RAM, read-only artifact, local database, then computation.
- Dashboard rendering uses copied statistics; database counts and sizes are read in the background.
