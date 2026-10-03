module CachedSQLiteExt

# The disk caches of `DiskCache` (see `docs/src/disk.md`): per function, an optional read-only
# artifact and one SQLite database per node, in WAL mode, shared by the processes of the node.
# Nodes write separate files, as WAL needs shared memory, which network file systems do not
# give across nodes. Disk errors never fail a call: they warn once and the call goes on.

using Cached: Cached, DiskCache, _compute, _fname, _owner, _ispackage, _within, instrument,
    _resolve_settings, _cached_section, _package_section, get_scratch!, sha256
using SQLite: SQLite, DBInterface
using Serialization: serialize, deserialize, writeheader

const BUSY_TIMEOUT = 60_000 # ms that a write waits for another process holding the write lock

struct Store
    db::SQLite.DB
    get::SQLite.Stmt
    put::SQLite.Stmt
    lock::ReentrantLock # statements are not safe to use from several threads at once
end

function Store(path; immutable = false)
    if immutable # an artifact: read-only, and no locks
        db = SQLite.DB(string("file:", replace(path, '%' => "%25", '?' => "%3f", '#' => "%23"), "?mode=ro&immutable=1"))
    else
        mkpath(dirname(path))
        db = SQLite.DB(path)
    end
    try
        SQLite.busy_timeout(db, BUSY_TIMEOUT)
        # Processes creating a database at once can find it locked without the busy timeout
        # applying (switching to WAL needs an exclusive lock), so retry.
        locked(_, e) = e isa SQLite.SQLiteException && occursin("locked", e.msg)
        immutable || retry(() -> setup(db); delays = (0.01 + 0.05rand() for _ in 1:50), check = locked)()
        get = SQLite.Stmt(db, "SELECT value FROM entries WHERE keyhash = ?1 AND key = ?2")
        put = SQLite.Stmt(db, "INSERT OR REPLACE INTO entries VALUES (?1, ?2, ?3)")
        return Store(db, get, put, ReentrantLock())
    catch
        close(db)
        rethrow()
    end
end

# WAL mode is persistent, so only a new database is switched to it.
function setup(db)
    scalar(db, "PRAGMA journal_mode") == "wal" || SQLite.execute(db, "PRAGMA journal_mode = WAL")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS entries (keyhash BLOB PRIMARY KEY, key BLOB NOT NULL, value BLOB NOT NULL)")
    SQLite.execute(db, "PRAGMA synchronous = NORMAL") # durable across crashes of the process
    return nothing
end

# The first column of the first row of `sql`, finalized right away to end its read transaction.
function scalar(db, sql)
    stmt = SQLite.Stmt(db, sql; register = false)
    try
        return first(DBInterface.execute(stmt, ()))[1]
    finally
        DBInterface.close!(stmt)
    end
end

function load(s::Store, h, kb)
    return @lock s.lock begin
        q = DBInterface.execute(s.get, (h, kb))
        try
            row = iterate(q)
            row === nothing ? nothing : first(row)[1]
        finally
            DBInterface.close!(q) # ends the read transaction
        end
    end
end

# ---- the stores of a function, opened on first use ----

struct Stores
    f::Any
    artifact::Union{Nothing, Store}
    node::Union{Nothing, Store}
    hits::Threads.Atomic{Int} # lookups in this process, for `disk_cache_stats`
    misses::Threads.Atomic{Int}
end
Stores(f, artifact, node) = Stores(f, artifact, node, Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))

const STORES = IdDict{Any, Stores}() # typeof(f) => its stores
const LOCK = ReentrantLock()

_sanitize(s) = replace(string(s), r"[^A-Za-z0-9_.]" => c -> join("%" * string(b; base = 16, pad = 2) for b in codeunits(c)))

# `<Module>.<f>-v<version>`: the file name of an artifact, followed by `-<host>` on a node.
storename(f) = string(_sanitize(join((fullname(parentmodule(typeof(f)))..., _fname(f)), '.')), "-v", _sanitize(Cached.diskversion(f)))

# Without the `disk_path` preference: a scratch space of the package owning `f`, or of Cached.
diskdir(f, path) = !isempty(path) ? path : _ispackage(_owner(f)) ? get_scratch!(_owner(f), "Cached") :
    get_scratch!(Cached, string(nameof(_owner(f))))

function stores(f::F) where {F}
    s = @lock LOCK get(STORES, F, nothing)
    s === nothing || return s
    new = open_stores(f) # outside the lock: opening may wait for the busy timeout
    s = @lock LOCK get!(STORES, F, new)
    s === new || close_stores(new)
    return s
end

function open_stores(f)
    settings = _resolve_settings(_fname(f), _cached_section(), _package_section(f))
    settings.disk || return Stores(f, nothing, nothing)
    dir = Cached.disk_artifact(f)
    artifact = dir === nothing ? nothing : attempt(() -> Store(joinpath(dir, storename(f) * ".sqlite"); immutable = true), "open the disk artifact of `$(_fname(f))` in $dir")
    path = joinpath(diskdir(f, settings.disk_path), string(storename(f), '-', _sanitize(gethostname()), ".sqlite"))
    return Stores(f, artifact, attempt(() -> Store(path), "open the disk cache of `$(_fname(f))` at $path"))
end

close_stores(s::Stores) = foreach(x -> x === nothing || close(x.db), (s.artifact, s.node))
close_all() = @lock LOCK (foreach(close_stores, values(STORES)); empty!(STORES); nothing)

__init__() = atexit(close_all) # merges the write-ahead logs into the databases

# `f()`, or `nothing` if it throws, with a warning (once per message) unless `msg === nothing`.
function attempt(f, msg)
    return try
        f()
    catch e
        e isa InterruptException && rethrow()
        msg === nothing || @warn "Cached: cannot $msg; continuing without it" exception = e maxlog = 1 _id = Symbol(msg)
        nothing
    end
end

function tobytes(::Type{S}, x) where {S}
    io = IOBuffer()
    s = S(io)
    writeheader(s)
    serialize(s, x)
    return take!(io)
end

# ---- the lookup ----

function Cached.disk_lookup(f::F, ::DiskCache{S}, ::Type{V}, key, args, kw, o) where {F, S, V}
    s = stores(f)
    s.artifact === nothing && s.node === nothing && return _compute(f, o, args, kw)
    return instrument(f, Val(:disk), () -> lookup(f, s, S, V, key, args, kw, o), o)
end

function lookup(f::F, s::Stores, ::Type{S}, ::Type{V}, key, args, kw, o) where {F, S, V}
    # callable objects with fields share the store of their type, so they are part of the key
    kb = attempt(() -> tobytes(S, Base.issingletontype(F) ? key : (f, key)), "serialize a key of `$(_fname(f))`")
    kb === nothing && (Threads.atomic_add!(s.misses, 1); return _compute(f, o, args, kw))
    h = sha256(kb)
    for store in (s.artifact, s.node)
        store === nothing && continue
        bytes = attempt(() -> load(store, h, kb), "read the disk cache at $(store.db.file)")
        bytes === nothing && continue
        # an entry that cannot be read, or of another type, is a miss and is overwritten
        v = attempt(() -> Some(deserialize(S(IOBuffer(bytes)))), nothing)
        v !== nothing && something(v) isa V && (Threads.atomic_add!(s.hits, 1); return something(v)::V)
    end
    Threads.atomic_add!(s.misses, 1)
    v = _compute(f, o, args, kw)
    node = s.node
    node === nothing || attempt("write `$(_fname(f))` to the disk cache at $(node.db.file)") do
        vb = tobytes(S, v)
        @lock node.lock SQLite.execute(node.put, (h, kb, vb)) # one statement is one transaction
    end
    return v
end

# ---- management ----

selector(f) = (stores(f); s -> s.f isa typeof(f))
selector(m::Module) = s -> _within(parentmodule(typeof(s.f)), m)
selected(x) = (select = selector(x); [s for s in @lock(LOCK, collect(values(STORES))) if s.node !== nothing && select(s)])

function Cached.disk_cache_info(x)
    return map(selected(x)) do s
        path = s.node.db.file
        entries = @lock s.node.lock scalar(s.node.db, "SELECT count(*) FROM entries")::Int
        s.f => (; path, entries, bytes = filesize(path) + filesize(path * "-wal"))
    end
end

Cached.disk_cache_stats() = Pair{Any, @NamedTuple{hits::Int, misses::Int}}[
    s.f => (; hits = s.hits[], misses = s.misses[]) for s in @lock(LOCK, collect(values(STORES))) if s.artifact !== nothing || s.node !== nothing
]

Cached.empty_disk_caches!(x) = foreach(s -> @lock(s.node.lock, SQLite.execute(s.node.db, "DELETE FROM entries")), selected(x))

function Cached.export_disk_cache(f, dir::AbstractString)
    node = stores(f).node
    node === nothing && throw(ArgumentError("disk caching is disabled for `$(_fname(f))`"))
    path = joinpath(dir, storename(f) * ".sqlite")
    ispath(path) && throw(ArgumentError("$path exists"))
    mkpath(dir)
    @lock node.lock SQLite.execute(node.db, "VACUUM INTO ?1", (path,)) # compact and consistent
    db = SQLite.DB(path)
    try
        SQLite.execute(db, "PRAGMA journal_mode = DELETE") # readable from a read-only directory
    finally
        close(db)
    end
    return path
end

end # module CachedSQLiteExt
