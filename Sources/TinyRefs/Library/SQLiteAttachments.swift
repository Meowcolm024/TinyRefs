import Foundation
import GRDB

extension SQLiteLibrary {
    @discardableResult
    public func attachFile(at source: URL, to referenceID: UUID) async throws -> AttachmentRecord {
        try await withFileLock { db in
            try Self.requireActiveReference(referenceID, in: db)
            let input = source.resolvingSymlinksInPath()
            let filename = source.lastPathComponent
            guard source.isFileURL, LibraryFiles.isBasename(filename),
                  try files.fileType(at: input) == .typeRegular else {
                throw LibraryError.invalidAttachmentSource(source.path)
            }

            let id = UUID()
            let row = AttachmentRow(
                id: id,
                referenceID: referenceID,
                relativePath: "attachments/\(id.databaseKey)/\(filename)",
                originalFilename: filename
            )
            let stage = try files.stage()
            try FileManager.default.copyItem(at: input, to: stage.appendingPathComponent(filename))
            try FileManager.default.moveItem(at: stage, to: files.attachmentDirectory(for: id))
            try db.inTransaction {
                try row.insert(db)
                return .commit
            }
            return row.attachment
        }
    }

    public func detachAttachment(id: UUID) async throws {
        try await withFileLock { db in
            let row = try Self.requireAttachment(id, in: db)
            try Self.requireActiveReference(row.referenceID, in: db)
            try db.inTransaction {
                guard try row.delete(db) else { throw LibraryError.attachmentNotFound(id) }
                return .commit
            }
            try files.removeAfterCommit([files.attachmentDirectory(for: id)])
        }
    }

    @discardableResult
    public func reassignAttachment(id: UUID, to referenceID: UUID) async throws -> AttachmentRecord {
        try await withFileLock { db in
            var row = try Self.requireAttachment(id, in: db)
            try Self.requireActiveReference(row.referenceID, in: db)
            if row.referenceID != referenceID {
                try Self.requireActiveReference(referenceID, in: db)
                row.referenceID = referenceID
                try db.inTransaction {
                    try row.update(db, columns: [AttachmentRow.CodingKeys.referenceID])
                    return .commit
                }
            }
            return row.attachment
        }
    }

    public func attachmentFile(for referenceID: UUID, attachmentID: UUID? = nil) async throws -> URL {
        try await withFileLock { db in
            _ = try Self.requireReference(referenceID, in: db)
            if let attachmentID {
                let row = try Self.requireAttachment(attachmentID, in: db)
                guard row.referenceID == referenceID else { throw LibraryError.attachmentNotFound(attachmentID) }
                guard let file = try files.availableFile(for: row.attachment) else {
                    throw LibraryError.missingAttachmentFile(row.originalFilename)
                }
                return file
            }

            for attachment in try Self.attachmentRecords(for: referenceID, in: db) {
                if let file = try files.availableFile(for: attachment) { return file }
            }
            throw LibraryError.noAvailableAttachments(referenceID)
        }
    }

    static func attachmentRecords(for referenceID: UUID, in db: Database) throws -> [AttachmentRecord] {
        try AttachmentRow.filter(AttachmentRow.CodingKeys.referenceID == referenceID.databaseKey)
            .order(AttachmentRow.CodingKeys.originalFilename, AttachmentRow.CodingKeys.id)
            .fetchAll(db)
            .map(\.attachment)
    }

    private static func requireAttachment(_ id: UUID, in db: Database) throws -> AttachmentRow {
        guard let row = try AttachmentRow.fetchOne(db, key: id.databaseKey) else {
            throw LibraryError.attachmentNotFound(id)
        }
        return row
    }

    private static func requireActiveReference(_ id: UUID, in db: Database) throws {
        guard try requireReference(id, in: db).trashedAt == nil else {
            throw LibraryError.referenceInTrash(id)
        }
    }
}
