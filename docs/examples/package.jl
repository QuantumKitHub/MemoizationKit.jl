# A private package and preferences environment for executable documentation examples.
# Loading without precompilation lets it reuse the documentation process's dependencies.
let env = mktempdir(), uid = Base.UUID(rand(UInt128))
    src = joinpath(env, "MyPackage", "src")
    mkpath(src)
    write(
        joinpath(dirname(src), "Project.toml"),
        "name = \"MyPackage\"\nuuid = \"$uid\"\n[deps]\nMemoizationKit = \"$(Base.PkgId(MemoizationKit).uuid)\"\n",
    )
    write(
        joinpath(src, "MyPackage.jl"),
        "__precompile__(false)\nmodule MyPackage\nusing MemoizationKit\n@cached expensive(x) = x^2\nend\n",
    )
    pushfirst!(LOAD_PATH, env)
    package = try
        Base.require(Base.PkgId(uid, "MyPackage"))
    finally
        popfirst!(LOAD_PATH)
    end
    write(
        joinpath(env, "Project.toml"),
        "[deps]\nMemoizationKit = \"$(Base.PkgId(MemoizationKit).uuid)\"\nMyPackage = \"$uid\"\n",
    )
    with_preferences = function (f)
        original = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = joinpath(env, "Project.toml")
        try
            return Base.invokelatest(cd, f, env)
        finally
            Base.ACTIVE_PROJECT[] = original
        end
    end
    (; package, with_preferences)
end
