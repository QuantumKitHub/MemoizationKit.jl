"""
    @cached function f(args...; kwargs...) ... end
    @cached f(args...; kwargs...) = ...

Memoize a method. The body becomes a method of [`Cached.implementation`](@ref), and `f` keeps
its signature (including default values and keyword arguments) but looks up the result in a
cache selected by [`CacheStyle`](@ref)`(f, args...)`.

The cache key is the tuple of positional arguments, followed by a `NamedTuple` of the keyword
arguments if there are any. Results are stored in typed caches, one per key type: the value
type is the return type annotation if present (it may depend on `where` parameters), and the
inferred return type otherwise (or `Any` if inference does not give a concrete type).

Works for any method definition: qualified names (`function Base.f(...)`), operators and
callable objects (`(x::Foo)(args...)`). Use [`uncached`](@ref) to bypass the cache.
"""
macro cached(ex)
    def = ExprTools.splitdef(ex)
    haskey(def, :name) || throw(ArgumentError("@cached cannot be used on anonymous functions"))
    fname = def[:name]

    # the function argument of `implementation`, and the value forwarded to it
    if Meta.isexpr(fname, :(::)) # callable object
        fself = length(fname.args) == 1 ? gensym(:self) : fname.args[1]
        selfarg = Expr(:(::), fself, fname.args[end])
        def[:name] = selfarg
    else
        fself = fname
        selfarg = :(::typeof($fname))
    end

    args = map(_nameargs, get(def, :args, []))
    kwargs = get(def, :kwargs, [])
    def[:args] = args

    impl = copy(def)
    impl[:name] = :($Cached.implementation)
    impl[:args] = [selfarg; map(_nodefault, args)]
    isempty(kwargs) || (impl[:kwargs] = map(_nodefault, kwargs))

    vt = get(def, :rtype, nothing)
    positional = Expr(:tuple, map(_forward, args)...)
    keywords = Expr(:tuple, Expr(:parameters, map(_forward, kwargs)...))
    style = :($CacheStyle($fself, $(positional.args...)))
    def[:body] = :($call($fself, $style, $vt, $positional, $keywords))

    # the wrapper goes first, so that `typeof(f)` exists when the implementation is defined
    return esc(
        quote
            Base.@__doc__ $(ExprTools.combinedef(def))
            $(ExprTools.combinedef(impl))
            $(Meta.isexpr(fname, :(::)) ? nothing : fname)
        end
    )
end

_argname(a::Symbol) = a
function _argname(a::Expr)
    Meta.isexpr(a, (:kw, :(...))) && return _argname(a.args[1])
    Meta.isexpr(a, :(::)) && length(a.args) == 2 && return a.args[1]
    throw(ArgumentError("@cached: unsupported argument `$a`"))
end

# Give anonymous arguments (`::T`) a name, so that they can be forwarded.
_nameargs(a) = Meta.isexpr(a, :(::)) && length(a.args) == 1 ? Expr(:(::), gensym(:arg), a.args[1]) :
    Meta.isexpr(a, (:kw, :(...))) ? Expr(a.head, _nameargs(a.args[1]), a.args[2:end]...) : a

_nodefault(a) = Meta.isexpr(a, :kw) ? a.args[1] : a
_forward(a) = Meta.isexpr(a, :(...)) ? Expr(:(...), _argname(a)) : _argname(a)
