# TinyRefs

A minimal reference manager for macOS.

## Build and test

Use macOS 14 or later, Swift 6.4 or later, and a Rust toolchain that supports
the 2024 edition.

Run `make build` to build the Rust static library and link the SwiftPM
executables `TinyRefsApp` and `tinyrefs`. Run `make test` to run the Rust and
Swift test suites.
When running SwiftPM directly, run `make rust` first to create the archive it
links.

## Library storage

`SQLiteLibrary(directory:)` opens or creates `library.sqlite` and
`attachments/` in the library directory and runs the GRDB migrations. The public `ReferenceReader`,
`ReferenceStore`, and `CollectionStore` protocols let callers use the same
asynchronous API with a test double.

## Manage a library from the command line

The CLI uses `~/Library/Application Support/TinyRefs` by default. Use
`--database <directory>` to select a different library directory.

```sh
tinyrefs=.build/debug/tinyrefs
"$tinyrefs" --database "scratch/reading library" create Bernardy2017 article --field 'title={Linear Haskell}'
"$tinyrefs" --database "scratch/reading library" query Haskell
"$tinyrefs" --database "scratch/reading library" collection create "Type systems"
"$tinyrefs" --help
```

The CLI also supports editing and showing references, printing citation keys,
moving references to Trash and restoring them, and managing nested collections
and memberships. Use `<command> --help` for command-specific options.

## Import a bibliography

```sh
.build/debug/tinyrefs import "path/to/references.bib"
```

This first import milestone reads one UTF-8 `.bib` file and prints its
bibliography as a JSON array. Each entry has a `citation_key`, an `entry_type`,
and a `fields` object containing self-contained BibLaTeX expressions. Use
brace-delimited entries such as `@book{key, title = {A book}}`. Parse and file
errors go to stderr and return a nonzero exit status.
