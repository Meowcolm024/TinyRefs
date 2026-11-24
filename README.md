# TinyRefs

A minimal reference manager for macOS.

## Build and test

Use macOS 14 or later, Swift 6.4 or later, and a Rust toolchain that supports
the 2024 edition.

Run `make build` to build the Rust static library and link the SwiftPM
command-line executable. Run `make test` to run the Rust and Swift test suites.
When running SwiftPM directly, run `make rust` first to create the archive it
links.

## Import a bibliography

```sh
.build/debug/tinyrefs import "path/to/references.bib"
```

This first import milestone reads one UTF-8 `.bib` file and prints its
bibliography as a JSON array. Each entry has a `citation_key`, an `entry_type`,
and a `fields` object containing self-contained BibLaTeX expressions. Use
brace-delimited entries such as `@book{key, title = {A book}}`. Parse and file
errors go to stderr and return a nonzero exit status.
