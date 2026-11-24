import CBibLaTeX
import Foundation

public enum BibLaTeX {
    public enum ImportError: LocalizedError {
        case invalidInput(String)
        case parse(String)
        case bridge(String)

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message), .parse(let message), .bridge(let message):
                message
            }
        }
    }

    /// Parses UTF-8 BibLaTeX and returns the JSON produced by the Rust bridge.
    public static func importJSON(from data: Data) throws -> String {
        let result = data.withUnsafeBytes { input in
            let bytes = input.bindMemory(to: UInt8.self)
            return tinyrefs_biblatex_parse(bytes.baseAddress, bytes.count)
        }
        defer { tinyrefs_biblatex_free(result) }

        let bytes = UnsafeBufferPointer(start: result.data, count: result.len)
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw ImportError.bridge("The BibLaTeX bridge returned invalid UTF-8.")
        }

        switch Int(result.status) {
        case TINYREFS_BIBLATEX_OK:
            return text
        case TINYREFS_BIBLATEX_INVALID_INPUT:
            throw ImportError.invalidInput(text)
        case TINYREFS_BIBLATEX_PARSE_ERROR:
            throw ImportError.parse(text)
        default:
            throw ImportError.bridge(text)
        }
    }
}
