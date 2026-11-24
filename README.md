# TinyRefs

A minimal reference manager for macOS.

## Build and test

TinyRefs supports macOS 26 and later. Building it requires Swift 6.4 or later,
a macOS 26 or later SDK, and a Rust toolchain that supports the 2024 edition.

Run `make build` to build the Rust static library and link the SwiftPM
executables `TinyRefsApp` and `tinyrefs`. Run `make test` to run the Rust and
Swift test suites. The Makefile selects the macOS SDK through `xcrun` unless
`SDKROOT` is already set.

For direct SwiftPM builds, select the SDK and build the Rust archive first.

```sh
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
make rust
swift build
swift test
```

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

## Import and export a bibliography

```sh
"$tinyrefs" --database "scratch/reading library" import "path/to/references.bib" --collection "Type systems"
"$tinyrefs" --database "scratch/reading library" export
"$tinyrefs" --database "scratch/reading library" export references.bib
"$tinyrefs" --database "scratch/reading library" export --json
"$tinyrefs" import "path/to/references.bib" --json
```

`import` reads one UTF-8 `.bib` file in a single transaction and prints the
new reference UUIDs, one per line. Use brace-delimited entries such as
`@book{SystemT, title = {Gödel's System T}}`. An invalid entry or duplicate
citation key rolls back the whole import.

`export` prints active references as BibLaTeX to stdout. Supply a destination
to write the output to a file. Use `--collection` to select a collection on
import or export. `import --json` previews a bibliography without writing to
the library. `export --json` switches the output format to a JSON array.
Each JSON entry contains
`citation_key`, `entry_type`, and `fields`.

## Manage attachments

Attach any regular file with `tinyrefs attach <reference-uuid> <file>`. TinyRefs
prints the attachment UUID and keeps a managed copy under `attachments/`. Use
`show <reference-uuid>` to list attachment IDs, then use
`open <reference-uuid> --attachment <attachment-uuid>` to open one in its default
macOS app. Use `reassign <attachment-uuid> <reference-uuid>` to change its owner
or `detach <attachment-uuid>` to remove its managed copy.

After `trash <reference-uuid>`, `purge <reference-uuid>` sends a recovery folder
containing `reference.bib` and the available attachments to macOS Trash.
