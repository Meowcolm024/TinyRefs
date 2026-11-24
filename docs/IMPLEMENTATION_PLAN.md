# TinyRefs Implementation Plan

Implement the shared library and CLI first so the data model and BibLaTeX workflow can be exercised before the GUI is connected. Use temporary library directories for tests and manual verification. [TinyRefs design](DESIGN.md)

## Stage 1 — Build and package structure

- Set up SwiftPM targets for the shared library, the SwiftUI app, and the `tinyrefs` executable. Add the Rust crate and its C interface target.
- Add a simple build entry point that runs Cargo before Swift links the static library. Document the supported macOS version and commands for building and testing both languages.
- Verify that both executables build from a clean checkout and that `cargo test` and `swift test` run.

## Stage 2 — SQLite library and collections

- Add GRDB migrations and Swift models for references, generic fields, collections, memberships, and attachment records. Use stable UUIDs, GRDB's query interface, foreign keys, and transactions for related changes. Expose reference and collection protocols so callers can substitute test doubles.
- Implement reference creation, editing, search, and collection membership. Give each collection an optional parent and support moving collections. Derive the Library, Unfiled Items, and Trash views from the stored state. Implement moving an entry to the library Trash and restoring it.
- Verify that citation key edits preserve identity and that trashed references reserve their keys. Test case-sensitive uniqueness for citation keys and collection names, which references appear in Unfiled Items, restoration after a collection is deleted, and foreign-key cascades. Verify that moving a collection rejects cycles and deleting a parent preserves its children.

## Stage 3 — BibLaTeX import and export

- Add Rust parsing and serialization for the shared UTF-8 JSON payload. Document C buffer ownership, return structured errors, and catch Rust panics at the boundary.
- Connect the bridge to Swift and validate metadata edits for BibLaTeX syntax. Import each `.bib` file in a single transaction, including collection membership when the caller selects a collection. Support exporting active references and serializing a single entry for recovery.
- Verify round-trips for unknown entry types and fields, Unicode, protected groups, and citation-key link fields. Test file-local macros, malformed input, and rollback for duplicates in the input or library.

## Stage 4 — Reference and collection CLI

- Use Swift Argument Parser for `import`, `export`, `query`, `show`, `key`, `create`, `edit`, collection management and membership commands, `trash`, and `restore`. Use the shared library and support the app's default library directory and `--database <directory>`.
- Verify the CLI against a scratch library. Import into a named collection, find and edit entries by UUID, and export and reimport into a fresh library. Test collection names with spaces, conflicting names and keys, and membership changes. Check that a trashed reference is discoverable via `query --trash` and returns to its collection on restore.

## Stage 5 — Managed PDFs and deletion to macOS Trash

- Implement staged PDF copies, attachment lookup and removal, and startup cleanup under the library lock. Use UUID-based attachment paths and retain the original display filename.
- Implement **Move to macOS Trash** for references in the library Trash. Package `reference.bib` and the available PDFs together, send the folder to macOS Trash, then remove the database row and managed copies.
- Add `attach`, `detach`, `open`, and `purge` to the CLI when the corresponding shared operations are available. Verify that `show` reports attachment UUIDs and that `open` can select one attachment.
- Use a temporary library and a simulated Trash handoff to test export, copy, and handoff failures. Verify that a failed attempt can be retried, that an interruption before the database commit leaves the entry restorable, and that startup cleans up managed copies left after commit.

## Stage 6 — Native macOS browsing and editing

- Build the resizable SwiftUI navigator, reference table, and inspector with independent panel toggles. Add the toolbar search field and display Library, Unfiled Items, collections, and Trash in the navigator.
- Connect editing, collection management, **Move to Trash**, **Restore**, and **Move to macOS Trash** to the shared library. Add **Copy Citation Key** for the selected reference.
- Verify that moving between scopes updates the center list, search and sorting use the current scope, and panel toggles remain easy to reach. Check that removing a collection membership can move an active entry to Unfiled Items.

## Stage 7 — Drag and drop and PDF reading

- Connect Finder `.bib` drops to the importer and PDF drops to the target reference. Allow dragging reference rows to collections. Use the same operations from menu and inspector actions.
- Open a PDF in the center on double-click and show references as indented rows under expandable navigator items. Add **Close PDF** to restore the table and **Open PDF in Preview** to the reference context menu.
- Verify valid and invalid drops, a drop onto an unselected reference, and import into a specific collection. Check the first available attachment, missing PDFs, and PDFKit navigation, zoom, text selection, and search. Verify that closing a PDF restores the previous table state and that the context menu opens the correct attachment in Preview.

## Stage 8 — Packaging and acceptance

- Build the macOS `.app` and CLI from a clean checkout. Run `cargo test` and `swift test` using the documented build order.
- Use a scratch library to import from the CLI, create a collection, add a reference, and attach a PDF. Verify the result in the app and open the PDF. Move the entry to the library Trash in the app, restore it from the CLI, then trash it again and use `purge` to send its recovery folder to macOS Trash.
- Confirm that the entry is gone from the app's Trash and that the recovery folder in macOS Trash contains the `.bib` and PDFs. Reimport the `.bib` into a scratch library and compare its metadata with the original reference.
