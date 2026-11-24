import Darwin
import Foundation
import TinyRefs

@main
enum ImportCommand {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        let usage = "Usage: tinyrefs import <file>"

        if arguments.isEmpty || Array(arguments) == ["--help"] {
            print(usage)
            return
        }

        guard arguments.count == 2, arguments.first == "import", let path = arguments.last else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(EX_USAGE)
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            print(try BibLaTeX.importJSON(from: data))
        } catch {
            FileHandle.standardError.write(Data("tinyrefs: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
