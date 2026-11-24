import Foundation
import GRDB

protocol LibraryRecord: Codable, FetchableRecord, PersistableRecord {}

extension LibraryRecord {
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}

struct ReferenceRow: LibraryRecord {
    static let databaseTableName = "bibliographic_references"
    static let fields = hasMany(ReferenceFieldRow.self).forKey("fields")

    let id: UUID
    var citationKey: String
    var entryType: String
    var trashedAt: Int64?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case citationKey = "citation_key"
        case entryType = "entry_type"
        case trashedAt = "trashed_at"
    }
}

struct ReferenceFieldRow: LibraryRecord {
    static let databaseTableName = "reference_fields"

    let referenceID: UUID
    let name: String
    let value: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case referenceID = "reference_id"
        case name, value
    }
}

struct CollectionRow: LibraryRecord {
    static let databaseTableName = "collections"

    let id: UUID
    var name: String
    var parentID: UUID?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name
        case parentID = "parent_id"
    }

    var collection: LibraryCollection {
        LibraryCollection(id: id, name: name, parentID: parentID)
    }
}

struct MembershipRow: LibraryRecord {
    static let databaseTableName = "collection_memberships"

    let collectionID: UUID
    let referenceID: UUID

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case collectionID = "collection_id"
        case referenceID = "reference_id"
    }

    var membership: CollectionMembership {
        CollectionMembership(collectionID: collectionID, referenceID: referenceID)
    }
}

struct AttachmentRow: LibraryRecord {
    static let databaseTableName = "attachments"

    let id: UUID
    let referenceID: UUID
    let relativePath: String
    let originalFilename: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case referenceID = "reference_id"
        case relativePath = "relative_path"
        case originalFilename = "original_filename"
    }

    var attachment: AttachmentRecord {
        AttachmentRecord(
            id: id,
            referenceID: referenceID,
            relativePath: relativePath,
            originalFilename: originalFilename
        )
    }
}
