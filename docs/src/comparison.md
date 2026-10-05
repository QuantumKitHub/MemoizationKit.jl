# Why Cached?

Cached is for memoization that needs ongoing management, especially in long-running or repeated computations.
Its niche is the combination of bounded RAM caches, optional persistence across runs, and tools to inspect and adjust caches while a program runs.
You can apply these controls per function or package without writing cache bookkeeping around each computation.

For example, a workload can keep frequently used results in RAM, recover older results from disk after a restart, and show which functions benefit from caching in the dashboard.
Strategy dispatch lets the same function share expensive results across tasks, keep independent task-local caches, or recompute cheap argument types.

## Choosing a package

| Package | Choose it when | Tradeoff |
| :-- | :-- | :-- |
| [Memoize.jl](https://github.com/JuliaCollections/Memoize.jl#usage) | You want a small `@memoize` API with a dictionary of your choice. | Limits and statistics depend on the container; persistence, a dashboard, and package-level settings require additional integration. |
| [Memoization.jl](https://github.com/marius311/Memoization.jl#readme) | You need to memoize individual calls or closures, as well as method definitions. | Its default cache is unbounded and not thread-safe; a custom container can address those needs, but the management and persistence tools require additional integration. |
| [LRUCache.jl](https://github.com/JuliaCollections/LRUCache.jl#readme) | You want a thread-safe cache dictionary with size limits, statistics, resizing, and eviction callbacks. | You write the function wrapper and management code yourself, or combine it with a memoization macro. |
| Cached.jl | You want bounded caches, per-type strategies, disk persistence, and live monitoring under one API. | The macro requires a method definition; disk results need explicit versioning and cleanup, and shared caches use locks. |

Memoize.jl and Memoization.jl both accept LRUCache.jl containers, so bounded memory and statistics are available without Cached.
Memoization.jl also preserves return-type inference.
Cached's benefit is that strategies, settings, persistence, and monitoring work together out of the box, with SQLite.jl and Tachikoma.jl loaded for their respective features.

## Differences that affect behavior

**Key matching:** Memoize.jl and Memoization.jl default to `IdDict`, matching arguments by identity; both allow a different dictionary.
By default, Cached's built-in caches match by value using `hash` and `isequal`, and distinguish argument types, so `f(3)` and `f(3.0)` occupy separate entries.
Custom cache keys can merge equivalent inputs across argument types; see [Custom cache keys](keys.md).
Value-based matching can reuse separately constructed equal keys, but hashing large keys can cost more than recomputing.

**Concurrency:** Cached's shared RAM caches are thread-safe by default, but their locks can contend and simultaneous misses may duplicate computation.
Task-local caches avoid sharing storage, at the cost of repeated computations and memory in each task; they are absent from the dashboard and global management API.
Memoization.jl documents thread safety for top-level functions with a thread-safe container, but not for closures or callable objects; see its [limitations](https://github.com/marius311/Memoization.jl#limitations).

**Invalidation:** Cached requires manual clearing after a method or external state changes.
Memoization.jl handles method redefinition for memoized definitions, though memoized individual calls require clearing; see its [redefinition behavior](https://github.com/marius311/Memoization.jl#limitations).
For Cached's persistent results, you must also update the disk version when results or stored types change.

**Persistence and limits:** Disk caching adds serialization and file I/O, so it suits results that are expensive to recompute.
Disk databases have no automatic eviction; RAM limits measure entries or values, not total process memory.
The dashboard monitors global caches used in the current process.
See [disk caching](disk.md) and [usage](usage.md) for the details.
