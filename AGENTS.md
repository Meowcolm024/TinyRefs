# AGENTS.md

## Project

A lightweight, native macOS reference manager built with SwiftUI, SwiftPM, and SQLite. The app opens PDFs in Preview. A Rust library provides BibLaTeX parsing and serialization through a C ABI.

The project uses SwiftPM, **not an Xcode project**.

## Architecture

- **SwiftUI** handles the app interface, reference editing, and library navigation.
- **Swift:** Reference models, SQLite persistence, attachment management, and application logic.
- **Rust:** BibLaTeX parsing and serialization only.
- **FFI:** A minimal C ABI with explicit ownership and error handling.

Keep the Swift and Rust implementations independent. Do not move application logic into Rust or introduce unnecessary abstractions.

SQLite is the source of truth. BibLaTeX files are imported and exported, not used as the live database.

References have stable internal IDs independent of their citation keys. Preserve unknown BibLaTeX fields during import/export.

PDF attachments are stored in an application-managed directory, not in SQLite.

## Build and Test

- Use `swift build` and `swift test` for Swift.
- Use `cargo build` and `cargo test` for Rust.
- Build the Rust static library before linking the Swift executable.
- Use SwiftPM for dependencies. Do not create an `.xcodeproj`.
- Prefer a simple build script or Makefile for coordinating Cargo and SwiftPM.

Run relevant tests after changes. Report any tests that could not be run.

## Conventions

- Prefer simple, idiomatic Swift and Rust.
- Use Swift concurrency for asynchronous operations.
- Keep UI code separate from persistence and parsing.
- Avoid force unwraps and silently ignored errors.
- Never unwind across the FFI boundary.
- Document memory ownership for every FFI function.
- Use parameterized SQL queries and transactions for related database changes.
- Keep filesystem operations explicit and recoverable.

## Scope

Prioritize:

1. Reference management and metadata editing.
2. BibLaTeX import/export.
3. PDF attachment management and viewing.
4. Search and collections.

Do not add cloud sync, browser integration, DOI lookup, PDF annotation, or complex citation processing unless requested.

## Working Guidelines

- Inspect existing code and conventions before modifying files.
- Make small, focused changes; avoid unrelated refactoring.
- Prefer existing dependencies over adding new ones.
- Add tests for parsing, persistence, and import/export behavior.
- Update documentation when build commands or architecture change.
- Do not claim a build or test succeeded unless it was actually run.
