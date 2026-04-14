//
//  FileTypeRegistry.swift
//  QuickLookCodeShared
//

import Foundation

/// Maps file extensions to grammar search terms and human-readable display names.
public enum FileTypeRegistry {

    public struct LanguageInfo {
        /// Substring passed to GrammarLoader to locate the TextMate grammar file.
        public let grammarSearch: String
        /// Human-readable language name shown in error / fallback messages.
        public let displayName: String
    }

    /// Returns language info for the given file extension (case-insensitive, no leading dot).
    public static func language(forExtension ext: String) -> LanguageInfo? {
        registry[ext.lowercased()]
    }

    // MARK: - Registry

    private static let registry: [String: LanguageInfo] = [

        // Apple
        "swift":    .init(grammarSearch: "swift",            displayName: "Swift"),
        "m":        .init(grammarSearch: "objective-c",      displayName: "Objective-C"),
        "mm":       .init(grammarSearch: "objective-c",      displayName: "Objective-C++"),
        "h":        .init(grammarSearch: "c",                displayName: "C Header"),

        // Web — core
        "js":       .init(grammarSearch: "javascript",       displayName: "JavaScript"),
        "mjs":      .init(grammarSearch: "javascript",       displayName: "JavaScript Module"),
        "cjs":      .init(grammarSearch: "javascript",       displayName: "CommonJS Module"),
        "jsx":      .init(grammarSearch: "javascriptreact",  displayName: "JSX"),
        "ts":       .init(grammarSearch: "typescript",       displayName: "TypeScript"),
        "mts":      .init(grammarSearch: "typescript",       displayName: "TypeScript ES Module"),
        "cts":      .init(grammarSearch: "typescript",       displayName: "TypeScript CJS Module"),
        "tsx":      .init(grammarSearch: "typescriptreact",  displayName: "TSX"),
        "html":     .init(grammarSearch: "html",             displayName: "HTML"),
        "htm":      .init(grammarSearch: "html",             displayName: "HTML"),
        "css":      .init(grammarSearch: "css",              displayName: "CSS"),
        "scss":     .init(grammarSearch: "scss",             displayName: "SCSS"),
        "sass":     .init(grammarSearch: "sass",             displayName: "Sass"),
        "less":     .init(grammarSearch: "less",             displayName: "Less"),

        // Systems
        "c":        .init(grammarSearch: "c",                displayName: "C"),
        "cpp":      .init(grammarSearch: "cpp",              displayName: "C++"),
        "cc":       .init(grammarSearch: "cpp",              displayName: "C++"),
        "cxx":      .init(grammarSearch: "cpp",              displayName: "C++"),
        "rs":       .init(grammarSearch: "rust",             displayName: "Rust"),
        "go":       .init(grammarSearch: "go",               displayName: "Go"),
        "zig":      .init(grammarSearch: "zig",              displayName: "Zig"),

        // Scripting
        "py":       .init(grammarSearch: "python",           displayName: "Python"),
        "pyi":      .init(grammarSearch: "python",           displayName: "Python Type Stub"),
        "rb":       .init(grammarSearch: "ruby",             displayName: "Ruby"),
        "sh":       .init(grammarSearch: "shellscript",      displayName: "Shell"),
        "bash":     .init(grammarSearch: "shellscript",      displayName: "Bash"),
        "zsh":      .init(grammarSearch: "shellscript",      displayName: "Zsh"),
        "ksh":      .init(grammarSearch: "shellscript",      displayName: "Korn Shell"),
        "fish":     .init(grammarSearch: "fish",             displayName: "Fish"),
        "ps1":      .init(grammarSearch: "powershell",       displayName: "PowerShell"),
        "lua":      .init(grammarSearch: "lua",              displayName: "Lua"),
        "pl":       .init(grammarSearch: "perl",             displayName: "Perl"),
        "pm":       .init(grammarSearch: "perl",             displayName: "Perl"),
        "r":        .init(grammarSearch: "r",                displayName: "R"),

        // JVM
        "java":     .init(grammarSearch: "java",             displayName: "Java"),
        "kt":       .init(grammarSearch: "kotlin",           displayName: "Kotlin"),
        "kts":      .init(grammarSearch: "kotlin",           displayName: "Kotlin Script"),
        "scala":    .init(grammarSearch: "scala",            displayName: "Scala"),
        "groovy":   .init(grammarSearch: "groovy",           displayName: "Groovy"),
        "gradle":   .init(grammarSearch: "groovy",           displayName: "Gradle"),

        // .NET
        "cs":       .init(grammarSearch: "csharp",           displayName: "C#"),
        "fs":       .init(grammarSearch: "fsharp",           displayName: "F#"),
        "fsx":      .init(grammarSearch: "fsharp",           displayName: "F# Script"),
        "vb":       .init(grammarSearch: "vb",               displayName: "Visual Basic"),

        // Data / Config
        "json":       .init(grammarSearch: "json",           displayName: "JSON"),
        "jsonc":      .init(grammarSearch: "jsonc",          displayName: "JSON with Comments"),
        "yaml":       .init(grammarSearch: "yaml",           displayName: "YAML"),
        "yml":        .init(grammarSearch: "yaml",           displayName: "YAML"),
        "toml":       .init(grammarSearch: "toml",           displayName: "TOML"),
        "xml":        .init(grammarSearch: "xml",            displayName: "XML"),
        "plist":      .init(grammarSearch: "xml",            displayName: "Property List"),
        "ini":        .init(grammarSearch: "ini",            displayName: "INI"),
        "properties": .init(grammarSearch: "ini",            displayName: "Java Properties"),
        "env":        .init(grammarSearch: "dotenv",         displayName: "Env"),
        "editorconfig": .init(grammarSearch: "editorconfig", displayName: "EditorConfig"),

        // Query
        "sql":      .init(grammarSearch: "sql",              displayName: "SQL"),
        "graphql":  .init(grammarSearch: "graphql",          displayName: "GraphQL"),
        "gql":      .init(grammarSearch: "graphql",          displayName: "GraphQL"),

        // Infra / DevOps
        "dockerfile": .init(grammarSearch: "dockerfile",     displayName: "Dockerfile"),
        "tf":       .init(grammarSearch: "terraform",        displayName: "Terraform"),
        "hcl":      .init(grammarSearch: "hcl",              displayName: "HCL"),
        "proto":    .init(grammarSearch: "proto3",           displayName: "Protobuf"),
        "makefile": .init(grammarSearch: "make",             displayName: "Makefile"),
        "mk":       .init(grammarSearch: "make",             displayName: "Makefile"),
        "bat":      .init(grammarSearch: "bat",              displayName: "Windows Batch"),
        "cmd":      .init(grammarSearch: "bat",              displayName: "Windows Command"),

        // Other popular
        "php":      .init(grammarSearch: "php",              displayName: "PHP"),
        "dart":     .init(grammarSearch: "dart",             displayName: "Dart"),
        "elm":      .init(grammarSearch: "elm",              displayName: "Elm"),
        "ex":       .init(grammarSearch: "elixir",           displayName: "Elixir"),
        "exs":      .init(grammarSearch: "elixir",           displayName: "Elixir Script"),
        "erl":      .init(grammarSearch: "erlang",           displayName: "Erlang"),
        "clj":      .init(grammarSearch: "clojure",          displayName: "Clojure"),
        "cljs":     .init(grammarSearch: "clojure",          displayName: "ClojureScript"),
        "cljc":     .init(grammarSearch: "clojure",          displayName: "Clojure Common"),
        "hs":       .init(grammarSearch: "haskell",          displayName: "Haskell"),
        "lhs":      .init(grammarSearch: "haskell",          displayName: "Literate Haskell"),
        "ml":       .init(grammarSearch: "ocaml",            displayName: "OCaml"),
        "mli":      .init(grammarSearch: "ocaml",            displayName: "OCaml Interface"),
        "jl":       .init(grammarSearch: "julia",            displayName: "Julia"),
        "vue":      .init(grammarSearch: "vue",              displayName: "Vue"),
        "svelte":   .init(grammarSearch: "svelte",           displayName: "Svelte"),
        "astro":    .init(grammarSearch: "astro",            displayName: "Astro"),
        "nix":      .init(grammarSearch: "nix",              displayName: "Nix"),
        "vim":      .init(grammarSearch: "viml",             displayName: "Vimscript"),
        "prisma":   .init(grammarSearch: "prisma",           displayName: "Prisma"),
        "sol":      .init(grammarSearch: "solidity",         displayName: "Solidity"),
        "wgsl":     .init(grammarSearch: "wgsl",             displayName: "WGSL"),
        "glsl":     .init(grammarSearch: "glsl",             displayName: "GLSL"),
        "hlsl":     .init(grammarSearch: "hlsl",             displayName: "HLSL"),
        "vert":     .init(grammarSearch: "glsl",             displayName: "GLSL Vertex"),
        "frag":     .init(grammarSearch: "glsl",             displayName: "GLSL Fragment"),
        "geom":     .init(grammarSearch: "glsl",             displayName: "GLSL Geometry Shader"),
        "tesc":     .init(grammarSearch: "glsl",             displayName: "GLSL Tess. Control Shader"),
        "tese":     .init(grammarSearch: "glsl",             displayName: "GLSL Tess. Eval. Shader"),
        "comp":     .init(grammarSearch: "glsl",             displayName: "GLSL Compute Shader"),

        // Templates
        "hbs":          .init(grammarSearch: "handlebars",   displayName: "Handlebars"),
        "handlebars":   .init(grammarSearch: "handlebars",   displayName: "Handlebars"),
        "pug":          .init(grammarSearch: "pug",          displayName: "Pug"),
        "jade":         .init(grammarSearch: "pug",          displayName: "Pug (Jade)"),

        // Markup / Docs
        "tex":      .init(grammarSearch: "latex",            displayName: "LaTeX"),
        "latex":    .init(grammarSearch: "latex",            displayName: "LaTeX"),
        "sty":      .init(grammarSearch: "latex",            displayName: "LaTeX Style"),
    ]
}
