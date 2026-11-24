public struct StructuredBibliographyFields: Codable, Equatable, Sendable {
    public struct Name: Codable, Equatable, Sendable {
        public let givenName: String
        public let familyName: String
        public let prefix: String
        public let suffix: String

        public var displayName: String {
            let name = [givenName, prefix, familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return [name, suffix].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    public struct PublicationDate: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case single, range, after, before, unparsed }

        public struct Parts: Codable, Equatable, Sendable {
            public let year: Int
            public let month: Int?
            public let day: Int?
        }

        public let text: String
        public let kind: Kind
        public let start: Parts?
        public let end: Parts?
        public let approximate: Bool
        public let uncertain: Bool
    }

    public let title: String?
    public let authors: [Name]
    public let editors: [Name]
    public let date: PublicationDate?
    public let eventDate: PublicationDate?
    public let originalDate: PublicationDate?
    public let accessDate: PublicationDate?
    public let keywords: [String]
    public let abstract: String?
    public let containerTitle: String?
    public let publisher: String?
    public let doi: String?
    public let url: String?
}
