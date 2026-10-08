using MemoizationKit: MemoizationKit
using Documenter: Documenter, DocMeta, deploydocs, makedocs

DocMeta.setdocmeta!(MemoizationKit, :DocTestSetup, :(using MemoizationKit); recursive = true)

makedocs(;
    modules = [MemoizationKit],
    authors = "Lukas Devos",
    sitename = "MemoizationKit.jl",
    format = Documenter.HTML(;
        canonical = "https://lkdvos.github.io/MemoizationKit.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Caches" => [
            "Configuration" => "configuration.md",
            "Eviction policies" => "eviction.md",
            "Disk caching" => "disk.md",
        ],
        "Monitoring" => [
            "Dashboard" => "dashboard.md",
            "Timing" => "timing.md",
        ],
        "Customization" => [
            "Custom cache keys" => "keys.md",
            "Implementing a cache" => "interface.md",
        ],
        "Reference" => "reference.md",
    ],
)

deploydocs(; repo = "github.com/lkdvos/MemoizationKit.jl", devbranch = "main", push_preview = true)
