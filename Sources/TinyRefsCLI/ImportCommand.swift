import ArgumentParser
import Foundation
import TinyRefs

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a BibLaTeX file into the library."
    )

    @OptionGroup var databaseOptions: DatabaseOptions
    @Argument(help: "The UTF-8 bibliography file.", completion: .file(extensions: ["bib"]))
    var file: String
    @Option(help: "Add imported references to this collection.")
    var collection: String?
    @Flag(help: "Print a JSON preview without saving references.")
    var json = false

    func validate() throws {
        if json, collection != nil {
            throw ValidationError("Choose either --json or --collection.")
        }
    }

    func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        if json {
            print(try BibLaTeX.importJSON(from: data))
            return
        }
        let library = try databaseOptions.openLibrary()
        let collectionID: UUID?
        if let collection {
            collectionID = try await requireCollection(named: collection, in: library).id
        } else {
            collectionID = nil
        }
        let imported = try await library.importBibLaTeX(data, into: collectionID)
        for reference in imported {
            print(displayID(reference.id))
        }
    }
}
