import CBibLaTeX
import Foundation

public enum BibLaTeX {
    public typealias ImportError = BridgeError

    public enum BridgeError: LocalizedError {
        case invalidInput(String)
        case parse(String)
        case invalidMetadata(String)
        case bridge(String)

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message), .parse(let message),
                 .invalidMetadata(let message), .bridge(let message):
                message
            }
        }
    }

    /// Parses UTF-8 BibLaTeX and returns the JSON produced by the Rust bridge.
    public static func importJSON(from data: Data) throws -> String {
        try call(tinyrefs_biblatex_parse, with: data)
    }

    /// Parses UTF-8 BibLaTeX into the shared metadata model.
    public static func references(from data: Data) throws -> [ReferenceMetadata] {
        let json = try importJSON(from: data)
        return try JSONDecoder().decode([ReferenceMetadata].self, from: Data(json.utf8))
    }

    /// Adds Rust-decoded fields to reference JSON without changing the stored expressions.
    public static func structuredJSON(for references: [ReferenceMetadata]) throws -> String {
        try call(tinyrefs_biblatex_describe, with: JSONEncoder().encode(references))
    }

    /// Interprets stored expressions in the same order as the supplied references.
    public static func structuredFields(for references: [ReferenceMetadata]) throws -> [StructuredBibliographyFields] {
        struct Entry: Decodable { let structured: StructuredBibliographyFields }
        let json = try structuredJSON(for: references)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([Entry].self, from: Data(json.utf8))
        guard entries.count == references.count else {
            throw BridgeError.bridge("The BibLaTeX bridge returned the wrong number of references.")
        }
        return entries.map(\.structured)
    }

    public static func structuredFields(for reference: ReferenceMetadata) throws -> StructuredBibliographyFields {
        try structuredFields(for: [reference])[0]
    }

    /// Serializes metadata as canonical UTF-8 BibLaTeX.
    public static func serialize(_ references: [ReferenceMetadata]) throws -> String {
        try call(tinyrefs_biblatex_serialize, with: JSONEncoder().encode(references))
    }

    /// Serializes one reference, including one retrieved from the library Trash.
    public static func serialize(_ reference: ReferenceMetadata) throws -> String {
        try serialize([reference])
    }

    private static func call(
        _ operation: (UnsafePointer<UInt8>?, Int) -> TinyRefsBibLaTeXResult,
        with data: Data
    ) throws -> String {
        let result = data.withUnsafeBytes { input in
            let bytes = input.bindMemory(to: UInt8.self)
            return operation(bytes.baseAddress, bytes.count)
        }
        defer { tinyrefs_biblatex_free(result) }

        let bytes = UnsafeBufferPointer(start: result.data, count: result.len)
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw BridgeError.bridge("The BibLaTeX bridge returned invalid UTF-8.")
        }

        switch Int(result.status) {
        case TINYREFS_BIBLATEX_OK:
            return text
        case TINYREFS_BIBLATEX_INVALID_INPUT:
            throw BridgeError.invalidInput(text)
        case TINYREFS_BIBLATEX_PARSE_ERROR:
            throw BridgeError.parse(text)
        case TINYREFS_BIBLATEX_INVALID_METADATA:
            throw BridgeError.invalidMetadata(text)
        default:
            throw BridgeError.bridge(text)
        }
    }
}
