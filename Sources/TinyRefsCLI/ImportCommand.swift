import ArgumentParser
import Foundation
import TinyRefs

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Parse a BibLaTeX file and print the resulting JSON."
    )

    @Argument(help: "The UTF-8 bibliography file.", completion: .file(extensions: ["bib"]))
    var file: String

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        print(try BibLaTeX.importJSON(from: data))
    }
}
