import ArgumentParser
import Foundation
import TinyRefs

extension TinyRefsCommand {
    struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search or list references.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @Argument(help: "Text to find in citation keys and fields.")
        var text: String?
        @Option(help: "Show active references in this collection.")
        var collection: String?
        @Flag(help: "Show active references without a collection.")
        var unfiled = false
        @Flag(help: "Show references in Trash.")
        var trash = false

        func validate() throws {
            if [collection != nil, unfiled, trash].count(where: { $0 }) > 1 {
                throw ValidationError("Choose at most one of --collection, --unfiled, and --trash.")
            }
        }

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let scope: ReferenceScope
            if let collection {
                scope = .collection(try await requireCollection(named: collection, in: library).id)
            } else if unfiled {
                scope = .unfiled
            } else if trash {
                scope = .trash
            } else {
                scope = .library
            }
            for reference in try await library.references(in: scope, matching: text) {
                let metadata = reference.metadata
                var columns = [displayID(reference.id), metadata.citationKey, metadata.entryType]
                if let title = metadata.fields["title"] {
                    columns.append(title.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                }
                print(columns.joined(separator: "\t"))
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a reference and its relationships as JSON.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let selected = try await reference.fetch(from: library)
            let collectionIDs = Set(try await library.memberships(for: selected.id).map(\.collectionID))
            let collections = try await library.collections().filter { collectionIDs.contains($0.id) }
            let attachments = try await library.attachments(for: selected.id)
            try printJSON(ReferenceDetails(
                id: displayID(selected.id),
                citationKey: selected.metadata.citationKey,
                entryType: selected.metadata.entryType,
                fields: selected.metadata.fields,
                trashedAt: selected.trashedAt,
                collections: collections.map(\.name),
                attachments: attachments.map(ReferenceDetails.Attachment.init)
            ))
        }
    }

    struct Key: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a reference's citation key.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            print(try await reference.fetch(from: library).metadata.citationKey)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a reference and print its UUID.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var fields: FieldOptions
        @Argument(help: ArgumentHelp("The citation key.", valueName: "key"))
        var citationKey: String
        @Argument(help: ArgumentHelp("The BibLaTeX entry type.", valueName: "type"))
        var entryType: String

        func run() async throws {
            let values = try fields.values()
            let library = try databaseOptions.openLibrary()
            let reference = try await library.createReference(ReferenceMetadata(
                citationKey: citationKey, entryType: entryType, fields: values
            ))
            print(displayID(reference.id))
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Edit an active reference.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument
        @OptionGroup var fields: FieldOptions
        @Option(help: "Replace the citation key.")
        var key: String?
        @Option(name: .customLong("type"), help: ArgumentHelp("Replace the BibLaTeX entry type.", valueName: "type"))
        var entryType: String?
        @Option(help: ArgumentHelp("Remove a field. May be repeated.", valueName: "name"))
        var unsetField: [String] = []

        func validate() throws {
            if key == nil, entryType == nil, fields.assignments.isEmpty, unsetField.isEmpty {
                throw ValidationError("Specify at least one edit.")
            }
        }

        func run() async throws {
            let values = try fields.values()
            let library = try databaseOptions.openLibrary()
            try await library.updateReference(id: reference.uuid, changes: ReferenceChanges(
                citationKey: key, entryType: entryType, fields: values, removedFields: unsetField
            ))
        }
    }

    struct Trash: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a reference to the library Trash.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            try await databaseOptions.openLibrary().moveReferenceToTrash(id: reference.uuid)
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restore a reference from the library Trash.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            try await databaseOptions.openLibrary().restoreReference(id: reference.uuid)
        }
    }
}

struct FieldOptions: ParsableArguments {
    @Option(name: .customLong("field"), help: ArgumentHelp(
        "Set a BibLaTeX field. May be repeated.", valueName: "name=value"
    ))
    var assignments: [String] = []

    func values() throws -> [String: String] {
        var fields: [String: String] = [:]
        for assignment in assignments {
            let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("Use --field 'name=value' with a BibLaTeX expression such as {} for an empty value.")
            }
            let name = String(parts[0])
            guard fields.updateValue(String(parts[1]), forKey: name) == nil else {
                throw LibraryError.duplicateFieldName(name)
            }
        }
        return fields
    }
}

private struct ReferenceDetails: Encodable {
    struct Attachment: Encodable {
        let id: String
        let originalFilename: String
        let relativePath: String

        init(_ record: AttachmentRecord) {
            id = displayID(record.id)
            originalFilename = record.originalFilename
            relativePath = record.relativePath
        }
    }

    let id: String
    let citationKey: String
    let entryType: String
    let fields: [String: String]
    let trashedAt: Date?
    let collections: [String]
    let attachments: [Attachment]
}
