# DESIGN.md

## Overview

A lightweight, native macOS reference manager inspired by Zotero. The application manages bibliographic references, imports and exports BibLaTeX files, and supports PDF attachments and viewing.

The design prioritizes simplicity, local storage, and integration with LaTeX workflows.

See the [implementation plan](IMPLEMENTATION_PLAN.md) for the build order and verification checks.

## Technology

- **SwiftUI:** Native macOS interface.
- **SwiftPM:** Build system and dependency management.
- **SQLite (GRDB):** Persistent reference metadata.
- **PDFKit:** PDF viewing.
- **Rust (`biblatex` crate):** BibLaTeX parsing and serialization.
- **C ABI:** FFI between Swift and Rust.

SwiftPM builds the SwiftUI application and a `tinyrefs` command-line executable. The application is packaged as a macOS `.app` without an Xcode project. Both executables link the Rust library statically.

## Architecture

The application has three main layers:

1. **UI:** SwiftUI views for browsing, editing, and reading.
2. **Application:** A shared Swift library for reference management, persistence, attachments, and import/export. The SwiftUI application and CLI both call this layer.
3. **BibLaTeX bridge:** Rust library exposed through a small C ABI.

SQLite is the source of truth. BibLaTeX files are imported and exported rather than synchronized bidirectionally.

Rust handles only bibliography parsing and serialization. Swift handles all application state, persistence, and filesystem operations.

The shared library exposes asynchronous reference and collection protocols for use by the app, the CLI, and test doubles. The SQLite implementation uses GRDB migrations, records, and its query interface.

## Data Model

### SQLite records

| Table | Columns | Constraints |
| --- | --- | --- |
| `bibliographic_references` | `id`, `citation_key`, `entry_type`, `trashed_at` | `id` is the primary key. `citation_key` is unique across the library with `BINARY` collation. `trashed_at` is a nullable integer containing Unix seconds. |
| `reference_fields` | `reference_id`, `name`, `value` | Primary key `(reference_id, name)`. `reference_id` points to `bibliographic_references`. |
| `attachments` | `id`, `reference_id`, `relative_path`, `original_filename` | `id` is the primary key. `reference_id` points to `bibliographic_references`. `relative_path` is unique. |
| `collections` | `id`, `name`, `parent_id` | `id` is the primary key. Nonblank names are globally unique with `BINARY` collation. `parent_id` is a nullable reference to another collection. |
| `collection_memberships` | `collection_id`, `reference_id` | Primary key `(collection_id, reference_id)`. Both columns are foreign keys. |

Columns are `TEXT NOT NULL` unless specified otherwise. Swift generates stable UUIDs for references, attachments, and collections and stores them as lowercase UUID strings. Citation keys retain their spelling and case. Imports and edits use the database's exact key comparison when checking for conflicts. References in Trash continue to reserve their citation keys until removed from the library.

Enable foreign-key enforcement on every connection. Removing a reference or collection cascades to its dependent field, attachment, or membership rows. The collection parent relationship uses `ON DELETE SET NULL`. Index `attachments(reference_id)`, `collection_memberships(reference_id)`, and `collections(parent_id)` for lookups and deletes. [SQLite foreign key support](https://www.sqlite.org/foreignkeys.html)

A collection can have one parent. Moving a collection keeps its descendants and memberships, and the library checks the proposed ancestry in the same transaction as the move. Deleting a collection moves its immediate children to the top level and keeps their descendants and memberships.

### Built-in library views

**Library** shows active references, whose `trashed_at` is `NULL`. A collection view shows its active direct members. **Unfiled Items** shows active references with zero collection memberships. New references and imports without a collection appear there automatically, as do active references whose last membership is removed. **Trash** shows references with a `trashed_at` value. These views are derived from the database.

Moving a reference to Trash sets `trashed_at` and keeps its metadata, memberships, and attachments. Restoring it clears `trashed_at`, returning it to all surviving collections or to Unfiled Items if it has no memberships.

### Bibliographic fields

Store BibLaTeX entry types and field names as open-ended text with ASCII lowercase names. A reference can have zero or more fields. A missing field has no row, and an explicit empty value has a row with the BibLaTeX expression `{}`. Each `value` stores a self-contained BibLaTeX expression, such as `{{NASA} mission}`, so that protected groups and TeX markup survive export. The reference list derives titles, authors, and dates from these fields for display, search, and sorting.

Validate citation keys, entry types, field names, and expressions for BibLaTeX syntax before saving. Save changes to a reference and its fields in one database transaction.

Fields such as `crossref` and `xdata` store BibLaTeX citation keys as part of their values. Those keys can refer to entries outside the library. When a citation key changes, users update any dependent BibLaTeX fields explicitly. The reference keeps its UUID, collection memberships, and attachments.

## Storage

The library consists of an SQLite database and a managed attachment directory.

```text
Library/
├── library.sqlite
└── attachments/
    └── <attachment-uuid>/
        └── document.pdf
```

The default library directory is `~/Library/Application Support/TinyRefs`. The app and CLI share that default. Each library directory holds its own database and attachment files.

Each attachment belongs to one reference, and a reference can have any number of PDFs. The database stores `attachments/<attachment-uuid>/document.pdf` relative to the library root. The app uses `original_filename` as the display label and generates the storage path from the attachment UUID.

When adding a PDF, stage the copy inside the library, move it to its final path, and then commit the attachment row. When removing an individual attachment, commit the database deletion before removing its file. Serialize attachment writes, trash actions, and recovery across processes with a library lock. On reopening an existing library, remove abandoned staging files and unreferenced attachment directories in the managed layout. Keep records for missing PDFs so the app can report which files are unavailable.

### Moving an entry to macOS Trash

When the user chooses **Move to macOS Trash** for an entry in the library Trash, stage one recovery folder named `TinyRefs-<reference-uuid>`. Use the shared exporter to write the entry and all its fields to `reference.bib`. Copy each available managed PDF into `attachments/<attachment-uuid>/` under its original basename. Report attachments that were already missing.

Move the complete folder to macOS Trash with `FileManager.trashItem`. An export, copy, or trash operation error leaves the reference and its managed files in the library Trash. [Foundation trash API](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))

After macOS accepts the folder, remove the reference row in a database transaction and then clean up the managed attachment directories. An interruption before the database commit leaves the reference and its files in the library Trash. A retry at that point may produce a second recovery folder. If interrupted after commit, library startup cleanup removes the unreferenced managed files.

## User Interface

Use a native macOS window with a unified toolbar, resizable split panes, and SF Symbols. Take layout cues from Xcode's navigator, editor, and inspector. The toolbar has independent show and hide buttons for the navigator on the left and inspector on the right. Both controls are also available in the **View** menu. [Apple's macOS toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars) · [Xcode window layout](https://developer.apple.com/documentation/xcode/configuring-the-xcode-project-window)

| Pane | Browsing references | Reading a PDF |
| --- | --- | --- |
| Left navigator | Select **Library**, **Unfiled Items**, a collection in the hierarchy, or **Trash**. Create, rename, move, and delete collections here. | Expand a navigator item with a disclosure triangle to browse its references as indented rows. Expand the current branch when the reader opens. |
| Center workspace | Sort references in the current navigator selection. Select a row to show its details in the inspector. | Show the PDF in the same window. Double-click another reference in the navigator to open its PDF in the center. |
| Right inspector | View metadata, collection memberships, and PDFs. Edit metadata and manage attachments for active references. | Show the inspector for the selected navigator row. |

The toolbar's **Search References** field uses a magnifying-glass icon. It filters the center reference list while browsing and filters reference rows in the navigator while reading. Focusing reference search in the reader reveals the navigator if it is hidden. Use **Find in PDF** to search within the open document.

In a collection, **Remove from Collection** removes the reference's membership.

Use **Move to Trash** on an active reference to send it to the library Trash. In that view, **Restore** returns the entry to the library and **Move to macOS Trash** exports and removes it from the library.

### Drag and drop

| Dragged item | Drop target | Result |
| --- | --- | --- |
| BibTeX or BibLaTeX `.bib` files from Finder | **Library**, **Unfiled Items**, a collection, or the center reference list for any of those views | Run the shared importer. A drop on a collection adds the imported references to it. A drop on the center reference list uses the current navigator selection. |
| `.pdf` files from Finder | An active reference row in the center list or navigator, or its attachment area in the inspector | Copy each file into the managed library and attach it to the target reference. |
| Active reference rows | A collection in the navigator | Add the references to that collection while keeping their existing memberships. |

Highlight valid drop targets during a drag and show import or attachment errors in the window. **File > Import** adds references to the selected collection when applicable. Otherwise, imported references appear in Unfiled Items. **Add PDF** in the inspector attaches a file to the selected active reference.

### Opening PDFs

Double-click a reference row to replace the center list with its first available PDF in the native PDFKit reader. Check attachments in the order shown in the inspector, which sorts by filename and uses the attachment UUID to break ties. The inspector lets users open any attachment directly. If the reference has no attachments, double-click shows its inspector. If it has attachment records but all files are missing, the app reports that the PDFs are unavailable.

The reader toolbar has a close icon labeled **Close PDF**. It restores the center reference list, including its previous collection, search, sort order, and selection.

Right-click a reference in the center list or navigator and choose **Open PDF in Preview** to open its first available PDF in the macOS Preview app. Enable this action for references with an available PDF.

The PDFKit reader supports navigation, zooming, selection, and search.

## Import and Export

The Rust bridge exposes two operations:

- **Import:** Parse BibLaTeX text into reference data.
- **Export:** Serialize reference data into BibLaTeX text.

The bridge exchanges entry types, citation keys, and field expressions as UTF-8 JSON. Swift owns library IDs, collections, and managed attachments. The Rust bridge provides explicit memory ownership and structured error reporting.

Import uses the crate's raw entry representation to preserve explicitly supplied fields. Expand file-local string macros into self-contained expressions, and report unresolved macros as import errors. Preserve link fields such as `crossref` and `xdata` because the crate's high-level parser resolves inheritance and drops `xdata`. [Rust `biblatex` parser source](https://github.com/typst/biblatex/blob/main/src/lib.rs)

Import each file in a single database transaction, including memberships when the import targets a collection. A malformed entry, duplicate field name after normalization, or duplicate citation key within the file or library fails the import without changing the library. Successful imports assign new UUIDs. Reference creation and editing reuse the serializer's BibLaTeX validation. Export produces canonical BibLaTeX with both known and unknown fields, and the same serializer can write a single reference for recovery. The round-trip guarantee covers entry data and value semantics. Formatting, comments, and standalone directives are outside that guarantee.

Automatic export to a configured `.bib` file may be added later.

## Command-line Interface

`tinyrefs` uses Swift Argument Parser and calls the shared library operations. Use `--database <directory>` before a storage command or with its options to select the library directory. The path may be absolute or relative to the current working directory. TinyRefs creates `library.sqlite` and `attachments/` in that directory if needed. Omit the option to use `~/Library/Application Support/TinyRefs`. Commands write results to stdout and report errors on stderr with a nonzero exit status.

Commands identify references and attachments by UUID. Collection commands use exact, case-sensitive names. Quote names and paths that contain spaces.

### References and BibLaTeX

| Command | Behavior |
| --- | --- |
| `import <file> [--collection <name>]` | Import the entire `.bib` file in one transaction. Print one new reference UUID per line. |
| `import <file> --json` | Print a JSON preview of the parsed bibliography without opening the library. |
| `export [<file>] [--collection <name>]` | Export active references from the library or the named collection as BibLaTeX. Print to stdout when the destination is omitted and write atomically when supplied. |
| `export --json [<file>] [--collection <name>]` | Export active references in the same metadata JSON format as the import preview. Print to stdout when the destination is omitted. |
| `query [<text>]` | List references or search by citation key and bibliographic fields. Print tab-separated UUID, citation key, entry type, and title when available. |
| `show <uuid>` | Print the reference's metadata, collections, and attachments as JSON, including attachment UUIDs. |
| `key <uuid>` | Print the citation key on its own for scripting or copying. |
| `create <key> <type> [--field <name=value>]` | Create a reference and print its UUID. |
| `edit <uuid> [--key <key>] [--type <type>] [--field <name=value>] [--unset-field <name>]` | Update the citation key, entry type, or fields of an active reference. |

`query` defaults to active references across the library. Pass one of `--collection <name>`, `--unfiled`, or `--trash` to choose a scope. `show` accepts active and trashed references. Repeat `--field` or `--unset-field` to edit multiple fields. Field values are BibLaTeX expressions such as `--field 'title={Linear Haskell}'`. When an edit names the same field in both options, the assignment takes precedence.

### Attachments

| Command | Behavior |
| --- | --- |
| `attach <uuid> <file.pdf>` | Copy a PDF into the managed library for an active reference and print the attachment UUID. |
| `detach <attachment-uuid>` | Remove the attachment from its active reference and clean up the managed file. |
| `open <uuid> [--attachment <attachment-uuid>]` | Open the first available PDF in Preview, or open a specific attachment of that reference. |

### Collections

| Command | Behavior |
| --- | --- |
| `collection list` | List collections as JSON with names, IDs, and parent IDs for nested collections. |
| `collection create <name> [--parent <name>]` | Create a named collection, optionally under a parent. |
| `collection rename <name> <new-name>` | Rename a collection while keeping its memberships. |
| `collection move <name> [--parent <name>]` | Move a collection under a parent or to the top level when the parent is omitted. |
| `collection delete <name>` | Delete the collection and its memberships. Its children move to the top level. |
| `collection add <name> <uuid>` | Ensure an active reference belongs to the collection. |
| `collection remove <name> <uuid>` | Remove an active reference's membership in the collection. |

### Trash

| Command | Behavior |
| --- | --- |
| `trash <uuid>` | Move an active reference to the library Trash. |
| `restore <uuid>` | Restore a trashed reference. |
| `purge <uuid>` | Send a trashed reference's `.bib` file and available PDFs to macOS Trash as a recovery folder, then remove the library record. |

## Initial Scope

The first version supports:

1. Creating, editing, searching, trashing, and restoring references, with a recovery folder sent to macOS Trash on final removal.
2. Importing and exporting `.bib` files.
3. Adding, removing, and viewing PDF attachments.
4. Organizing references into collections and finding uncategorized references in Unfiled Items.
5. Copying citation keys to the clipboard.
6. Managing references, attachments, collections, and Trash from the CLI, with BibLaTeX import and export.

## Non-Goals

The initial version does not support:

- Cloud synchronization or collaboration.
- Browser extensions or online metadata retrieval.
- PDF annotations.
- Word processor integration.
- Automatic citation formatting.
- Bidirectional synchronization with `.bib` files.

## Design Principles

- Prefer native macOS components and straightforward implementations.
- Keep the application local-first and usable offline.
- Keep Swift and Rust responsibilities clearly separated.
- Preserve bibliographic data during import and export.
- Avoid unnecessary dependencies and abstractions.
- Add features incrementally without complicating the core architecture.
