import ArgumentParser
import Foundation
import TinyRefs

@main
struct TinyRefsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tinyrefs",
        abstract: "Manage a TinyRefs reference library.",
        subcommands: [
            ImportCommand.self, ExportCommand.self, Query.self, Show.self, Key.self, Create.self, Edit.self,
            CollectionCommand.self, Trash.self, Restore.self,
        ]
    )

    @OptionGroup var databaseOptions: DatabaseOptions
}

struct DatabaseOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Library directory containing library.sqlite and attachments/. Defaults to ~/Library/Application Support/TinyRefs.",
        valueName: "directory"
    ))
    var database: String?

    func validate() throws {
        if database?.isEmpty == true {
            throw ValidationError("--database requires a library directory.")
        }
    }

    func openLibrary() throws -> SQLiteLibrary {
        let directory = database.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? SQLiteLibrary.defaultDirectoryURL
        return try SQLiteLibrary(directory: directory)
    }
}

struct ReferenceArgument: ParsableArguments {
    @Argument(help: "The reference UUID.", transform: parseUUID)
    var uuid: UUID

    private static func parseUUID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw ValidationError("Expected a reference UUID.")
        }
        return id
    }

    func fetch(from reader: any ReferenceReader) async throws -> BibliographicReference {
        guard let reference = try await reader.reference(id: uuid) else {
            throw LibraryError.referenceNotFound(uuid)
        }
        return reference
    }
}

func requireCollection(named name: String, in store: any CollectionStore) async throws -> LibraryCollection {
    let collections = try await store.collections()
    guard let match = collections.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) else {
        throw CLIError.unknownCollection(name)
    }
    return match
}

enum CLIError: LocalizedError {
    case unknownCollection(String)

    var errorDescription: String? {
        switch self {
        case .unknownCollection(let name):
            "Collection '\(name)' was not found."
        }
    }
}

func encodeJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

func printJSON(_ value: some Encodable) throws {
    print(String(decoding: try encodeJSON(value), as: UTF8.self))
}

func displayID(_ id: UUID) -> String {
    id.uuidString.lowercased()
}
