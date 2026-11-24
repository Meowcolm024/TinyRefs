import ArgumentParser
import Foundation
import TinyRefs

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export active references as BibLaTeX or JSON."
    )

    @OptionGroup var databaseOptions: DatabaseOptions
    @Argument(help: "The destination file. Omit to write to stdout.",
              completion: .file(extensions: ["bib", "json"]))
    var file: String?
    @Option(help: "Export active references in this collection.")
    var collection: String?
    @Flag(help: "Export the shared reference metadata as JSON.")
    var json = false

    func run() async throws {
        let library = try databaseOptions.openLibrary()
        let destination = file.map { URL(fileURLWithPath: $0) }
        if let destination { try validateDestination(destination, in: library) }

        let scope: ReferenceScope
        if let collection {
            scope = .collection(try await requireCollection(named: collection, in: library).id)
        } else {
            scope = .library
        }
        let metadata = try await library.references(in: scope).map(\.metadata)
        let data = try json ? encodeJSON(metadata) : Data(BibLaTeX.serialize(metadata).utf8)
        if let destination {
            try data.write(to: destination, options: .atomic)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            print(text, terminator: json ? "\n" : "")
        }
    }

    private func validateDestination(_ destination: URL, in library: SQLiteLibrary) throws {
        let databasePath = library.databaseURL.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        let databaseFiles = ["", "-journal", "-wal", "-shm"].map { databasePath + $0 }
        guard !databaseFiles.contains(where: { $0.caseInsensitiveCompare(destinationPath) == .orderedSame }) else {
            throw ValidationError("Choose a destination other than the library database files.")
        }
    }
}
