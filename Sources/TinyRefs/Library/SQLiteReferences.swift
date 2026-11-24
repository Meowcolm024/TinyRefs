import Foundation
import GRDB

extension SQLiteLibrary {
    public func reference(id: UUID) async throws -> BibliographicReference? {
        try await database.read { db in
            try Self.fetchReference(id, in: db)
        }
    }

    static func fetchReference(_ id: UUID, in db: Database) throws -> BibliographicReference? {
        try ReferenceRow.filter(key: id.databaseKey)
            .including(all: ReferenceRow.fields)
            .asRequest(of: ReferenceWithFields.self)
            .fetchOne(db)?
            .bibliographicReference
    }

    public func references(
        in scope: ReferenceScope,
        matching text: String? = nil
    ) async throws -> [BibliographicReference] {
        try await database.read { db in
            let id = ReferenceRow.CodingKeys.id
            let trashedAt = ReferenceRow.CodingKeys.trashedAt
            let memberIDs = MembershipRow.select(MembershipRow.CodingKeys.referenceID)
            var request = ReferenceRow.all()
            switch scope {
            case .library:
                request = request.filter(trashedAt == nil)
            case .unfiled:
                request = request.filter(trashedAt == nil && !memberIDs.sqlSubquery.contains(id))
            case .trash:
                request = request.filter(trashedAt != nil)
            case .collection(let collectionID):
                let collectionMembers = memberIDs.filter(
                    MembershipRow.CodingKeys.collectionID == collectionID.databaseKey
                )
                request = request.filter(trashedAt == nil && collectionMembers.sqlSubquery.contains(id))
            }

            if let text, !text.isEmpty {
                let term = text.lowercased()
                let fieldMatches = ReferenceFieldRow
                    .filter(Self.containsText(ReferenceFieldRow.CodingKeys.value, term))
                    .select(ReferenceFieldRow.CodingKeys.referenceID)
                request = request.filter(
                    Self.containsText(ReferenceRow.CodingKeys.citationKey, term)
                        || fieldMatches.sqlSubquery.contains(id)
                )
            }

            return try request.order(ReferenceRow.CodingKeys.citationKey)
                .including(all: ReferenceRow.fields)
                .asRequest(of: ReferenceWithFields.self)
                .fetchAll(db)
                .map(\.bibliographicReference)
        }
    }

    @discardableResult
    public func importBibLaTeX(
        _ data: Data,
        into collectionID: UUID? = nil
    ) async throws -> [BibliographicReference] {
        let entries = try BibLaTeX.references(from: data)
        return try await database.write { db in
            if let collectionID { _ = try Self.requireCollection(collectionID, in: db) }
            return try entries.map { metadata in
                let reference = try Self.insertReference(metadata, in: db)
                if let collectionID {
                    try MembershipRow(collectionID: collectionID, referenceID: reference.id).insert(db)
                }
                return reference
            }
        }
    }

    @discardableResult
    public func createReference(_ metadata: ReferenceMetadata) async throws -> BibliographicReference {
        let normalized = try Self.normalized(metadata)
        _ = try BibLaTeX.serialize(normalized)
        return try await database.write { db in
            try Self.insertReference(normalized, in: db)
        }
    }

    @discardableResult
    public func updateReference(
        id: UUID,
        metadata: ReferenceMetadata
    ) async throws -> BibliographicReference {
        let normalized = try Self.normalized(metadata)
        return try await writeReference(id: id) { _, _ in normalized }
    }

    @discardableResult
    public func updateReference(
        id: UUID,
        changes: ReferenceChanges
    ) async throws -> BibliographicReference {
        let newFields = try Self.normalizedFields(changes.fields)
        let removedFields = try changes.removedFields.map(Self.normalizedFieldName)
        return try await writeReference(id: id) { db, record in
            let currentFields = try ReferenceFieldRow.filter(ReferenceFieldRow.CodingKeys.referenceID == id.databaseKey)
                .fetchAll(db)
            var metadata = ReferenceWithFields(reference: record, fields: currentFields).bibliographicReference.metadata
            if let key = changes.citationKey { metadata.citationKey = key }
            if let type = changes.entryType { metadata.entryType = type }
            for name in removedFields {
                metadata.fields.removeValue(forKey: name)
            }
            metadata.fields.merge(newFields) { _, new in new }
            return try Self.normalized(metadata)
        }
    }

    private func writeReference(
        id: UUID,
        metadata: @Sendable (Database, ReferenceRow) throws -> ReferenceMetadata
    ) async throws -> BibliographicReference {
        try await database.write { db in
            var record = try Self.requireReference(id, in: db)
            guard record.trashedAt == nil else { throw LibraryError.referenceInTrash(id) }
            let updated = try metadata(db, record)
            _ = try BibLaTeX.serialize(updated)
            record.citationKey = updated.citationKey
            record.entryType = updated.entryType
            do {
                try record.update(db)
            } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw LibraryError.duplicateCitationKey(updated.citationKey)
            }
            try ReferenceFieldRow.filter(ReferenceFieldRow.CodingKeys.referenceID == id.databaseKey)
                .deleteAll(db)
            try Self.insertFields(updated.fields, for: id, in: db)
            return BibliographicReference(id: id, metadata: updated)
        }
    }

    public func moveReferenceToTrash(id: UUID) async throws {
        try await setTrashState(id: id, trashed: true)
    }

    public func restoreReference(id: UUID) async throws {
        try await setTrashState(id: id, trashed: false)
    }

    public func attachments(for referenceID: UUID) async throws -> [AttachmentRecord] {
        try await database.read { db in
            try Self.attachmentRecords(for: referenceID, in: db)
        }
    }

    private func setTrashState(id: UUID, trashed: Bool) async throws {
        try await withFileLock { db in
            var record = try Self.requireReference(id, in: db)
            guard (record.trashedAt != nil) != trashed else { return }
            record.trashedAt = trashed ? Int64(Date().timeIntervalSince1970) : nil
            try db.inTransaction {
                try record.update(db, columns: [ReferenceRow.CodingKeys.trashedAt])
                return .commit
            }
        }
    }

    private static func insertReference(_ metadata: ReferenceMetadata, in db: Database) throws -> BibliographicReference {
        let record = ReferenceRow(id: UUID(), citationKey: metadata.citationKey, entryType: metadata.entryType)
        do {
            try record.insert(db)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateCitationKey(metadata.citationKey)
        }
        try insertFields(metadata.fields, for: record.id, in: db)
        return BibliographicReference(id: record.id, metadata: metadata)
    }

    private static func insertFields(_ fields: [String: String], for id: UUID, in db: Database) throws {
        for (name, value) in fields {
            try ReferenceFieldRow(referenceID: id, name: name, value: value).insert(db)
        }
    }

    private static func normalized(_ metadata: ReferenceMetadata) throws -> ReferenceMetadata {
        guard !metadata.citationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.blankCitationKey
        }
        guard !metadata.entryType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.blankEntryType
        }

        return ReferenceMetadata(
            citationKey: metadata.citationKey,
            entryType: asciiLowercase(metadata.entryType),
            fields: try normalizedFields(metadata.fields)
        )
    }

    private static func normalizedFields(_ input: [String: String]) throws -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in input {
            let name = try normalizedFieldName(name)
            guard fields.updateValue(value, forKey: name) == nil else {
                throw LibraryError.duplicateFieldName(name)
            }
        }
        return fields
    }

    private static func normalizedFieldName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.blankFieldName
        }
        return asciiLowercase(name)
    }

    private static func asciiLowercase(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

private struct ReferenceWithFields: Decodable, FetchableRecord {
    let reference: ReferenceRow
    let fields: [ReferenceFieldRow]

    var bibliographicReference: BibliographicReference {
        let fieldValues = fields.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        return BibliographicReference(
            id: reference.id,
            metadata: ReferenceMetadata(
                citationKey: reference.citationKey,
                entryType: reference.entryType,
                fields: fieldValues
            ),
            trashedAt: reference.trashedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
