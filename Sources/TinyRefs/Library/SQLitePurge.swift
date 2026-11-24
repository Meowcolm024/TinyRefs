import Foundation
import GRDB

extension SQLiteLibrary {
    public func purgeReference(id: UUID) async throws -> PurgedReference {
        try await purgeReference(id: id) { package in
            var destination: NSURL?
            try FileManager.default.trashItem(at: package, resultingItemURL: &destination)
            return destination as URL?
        }
    }

    func purgeReference(
        id: UUID,
        moveToTrash: @Sendable (URL) throws -> URL?
    ) async throws -> PurgedReference {
        try await withFileLock { db in
            guard let reference = try Self.fetchReference(id, in: db) else {
                throw LibraryError.referenceNotFound(id)
            }
            guard reference.trashedAt != nil else { throw LibraryError.referenceNotInTrash(id) }

            let bibliography = try BibLaTeX.serialize(reference.metadata)
            let attachments = try Self.attachmentRecords(for: id, in: db)
            let stage = try files.stage()
            let package = stage.appendingPathComponent("TinyRefs-\(id.databaseKey)", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data(bibliography.utf8).write(to: package.appendingPathComponent("reference.bib"))

            var missing: [AttachmentRecord] = []
            for attachment in attachments {
                guard let source = try files.availableFile(for: attachment) else {
                    missing.append(attachment)
                    continue
                }
                guard LibraryFiles.isBasename(attachment.originalFilename) else {
                    throw LibraryError.invalidManagedPath(attachment.originalFilename)
                }
                let folder = package.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent(attachment.id.databaseKey, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(attachment.originalFilename))
            }

            let recoveryURL = try moveToTrash(package)
            try db.inTransaction {
                guard try ReferenceRow.deleteOne(db, key: id.databaseKey) else {
                    throw LibraryError.referenceNotFound(id)
                }
                return .commit
            }
            try files.removeAfterCommit([stage] + attachments.map { files.attachmentDirectory(for: $0.id) })
            return PurgedReference(recoveryURL: recoveryURL, missingAttachments: missing)
        }
    }
}
