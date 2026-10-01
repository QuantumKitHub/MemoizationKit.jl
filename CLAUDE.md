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
julia --project=/tmp/runic -e 'using Pkg; Pkg.add("Runic"); using Runic; Runic.main(["--inplace", "src", "test"])'
```

## Status

The package is being restarted from scratch. `research/` holds design notes from the first
prototype (the code is on the `archive/prototype` branch); treat them as inspiration, not a spec.
