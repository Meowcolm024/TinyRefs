import Foundation

public struct ReferenceMetadata: Equatable, Sendable {
    public var citationKey: String
    public var entryType: String
    /// Field names map to self-contained BibLaTeX expressions.
    public var fields: [String: String]

    public init(citationKey: String, entryType: String, fields: [String: String] = [:]) {
        self.citationKey = citationKey
        self.entryType = entryType
        self.fields = fields
    }
}

public struct ReferenceChanges: Sendable {
    public var citationKey: String?
    public var entryType: String?
    public var fields: [String: String]
    public var removedFields: [String]

    public init(
        citationKey: String? = nil,
        entryType: String? = nil,
        fields: [String: String] = [:],
        removedFields: [String] = []
    ) {
        self.citationKey = citationKey
        self.entryType = entryType
        self.fields = fields
        self.removedFields = removedFields
    }
}

public struct BibliographicReference: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var metadata: ReferenceMetadata
    public let trashedAt: Date?

    public init(id: UUID, metadata: ReferenceMetadata, trashedAt: Date? = nil) {
        self.id = id
        self.metadata = metadata
        self.trashedAt = trashedAt
    }
}

public struct LibraryCollection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?

    public init(id: UUID, name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public struct CollectionMembership: Equatable, Sendable {
    public let collectionID: UUID
    public let referenceID: UUID

    public init(collectionID: UUID, referenceID: UUID) {
        self.collectionID = collectionID
        self.referenceID = referenceID
    }
}

public struct AttachmentRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let referenceID: UUID
    public let relativePath: String
    public let originalFilename: String

    public init(id: UUID, referenceID: UUID, relativePath: String, originalFilename: String) {
        self.id = id
        self.referenceID = referenceID
        self.relativePath = relativePath
        self.originalFilename = originalFilename
    }
}

public enum ReferenceScope: Equatable, Sendable {
    case library
    case unfiled
    case trash
    case collection(UUID)
}

public enum LibraryError: LocalizedError, Equatable, Sendable {
    case referenceNotFound(UUID)
    case referenceInTrash(UUID)
    case collectionNotFound(UUID)
    case duplicateCitationKey(String)
    case duplicateCollectionName(String)
    case collectionCycle(UUID)
    case duplicateFieldName(String)
    case blankCitationKey
    case blankEntryType
    case blankFieldName
    case blankCollectionName

    public var errorDescription: String? {
        switch self {
        case .referenceNotFound(let id):
            "Reference \(id.databaseKey) was not found."
        case .referenceInTrash(let id):
            "Restore reference \(id.databaseKey) from Trash before editing it."
        case .collectionNotFound(let id):
            "Collection \(id.databaseKey) was not found."
        case .duplicateCitationKey(let key):
            "Citation key '\(key)' is already in use."
        case .duplicateCollectionName(let name):
            "Collection '\(name)' already exists."
        case .collectionCycle:
            "Moving the collection there would create a cycle."
        case .duplicateFieldName(let name):
            "Field '\(name)' was specified more than once."
        case .blankCitationKey:
            "A citation key must contain a non-whitespace character."
        case .blankEntryType:
            "An entry type must contain a non-whitespace character."
        case .blankFieldName:
            "A field name must contain a non-whitespace character."
        case .blankCollectionName:
            "A collection name must contain a non-whitespace character."
        }
    }
}
