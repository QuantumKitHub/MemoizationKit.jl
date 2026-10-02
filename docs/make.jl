using Cached: Cached
using Documenter: Documenter, DocMeta, deploydocs, makedocs

DocMeta.setdocmeta!(Cached, :DocTestSetup, :(using Cached); recursive = true)

makedocs(;
    modules = [Cached],
    authors = "Lukas Devos",
    sitename = "Cached.jl",
    format = Documenter.HTML(;
        canonical = "https://lkdvos.github.io/Cached.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md", "Configuration" => "configuration.md", "Dashboard" => "dashboard.md",
        "Timing" => "timing.md", "Implementing a cache" => "interface.md", "Reference" => "reference.md",
    ],
)

deploydocs(; repo = "github.com/lkdvos/Cached.jl", devbranch = "main", push_preview = true)
