import Foundation
import GRDB
import Testing
@testable import TinyRefs

@Test func attachmentsKeepOriginalNamesAndCanBeReassignedWithoutMovingFiles() async throws {
    try await withTemporaryLibrary { library, directory in
        let origin = try await library.createReference(.init(citationKey: "LinearHaskell", entryType: "article"))
        let destination = try await library.createReference(.init(citationKey: "SystemT", entryType: "book"))
        let source = directory.appendingPathComponent("Gödel’s System T.txt")
        let bytes = Data("Primitive recursion\n".utf8)
        try bytes.write(to: source)
        let attachment = try await library.attachFile(at: source, to: origin.id)
        let managed = try await library.attachmentFile(for: origin.id)
        #expect(managed.lastPathComponent == source.lastPathComponent)
        #expect(try Data(contentsOf: managed) == bytes)

        let directorySource = try library.files.stage()
        await #expect(throws: LibraryError.invalidAttachmentSource(directorySource.path)) {
            try await library.attachFile(at: directorySource, to: origin.id)
        }
        try await library.moveReferenceToTrash(id: destination.id)
        await #expect(throws: LibraryError.referenceInTrash(destination.id)) {
            try await library.reassignAttachment(id: attachment.id, to: destination.id)
        }
        try await library.restoreReference(id: destination.id)

        let moved = try await library.reassignAttachment(id: attachment.id, to: destination.id)
        #expect(moved.referenceID == destination.id)
        #expect(moved.id == attachment.id)
        #expect(moved.relativePath == attachment.relativePath)
        #expect(try await library.reassignAttachment(id: attachment.id, to: destination.id) == moved)
        #expect(try await library.attachments(for: origin.id).isEmpty)
        await #expect(throws: LibraryError.attachmentNotFound(attachment.id)) {
            try await library.attachmentFile(for: origin.id, attachmentID: attachment.id)
        }
        #expect(try await library.attachmentFile(for: destination.id, attachmentID: attachment.id) == managed)

        try await library.detachAttachment(id: attachment.id)
        #expect(try await library.attachments(for: destination.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managed.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: source) == bytes)
    }
}

@Test func startupRecoversAbandonedFilesAndPreservesMissingAttachmentRecords() async throws {
    try await withTemporaryLibrary { library, directory in
        let reference = try await library.createReference(.init(citationKey: "SystemT", entryType: "book"))
        let source = directory.appendingPathComponent("Notes.txt")
        try Data("Primitive recursion\n".utf8).write(to: source)
        let missing = try await library.attachFile(at: source, to: reference.id)
        let removed = try await library.attachFile(at: source, to: reference.id)
        let missingPath = try await library.attachmentFile(for: reference.id, attachmentID: missing.id)
        try FileManager.default.removeItem(at: missingPath)

        // Simulate an interruption after a detach committed and before it removed its files.
        try await library.database.write { db in
            _ = try AttachmentRow.deleteOne(db, key: removed.id.databaseKey)
        }
        let abandoned = try library.files.stage()
        try Data("unfinished".utf8).write(to: abandoned.appendingPathComponent("draft"))
        let unrelated = library.files.attachments.appendingPathComponent("README")
        try Data().write(to: unrelated)
        let unrelatedStagingFile = library.files.staging.appendingPathComponent("README")
        try Data().write(to: unrelatedStagingFile)

        let reopened = try SQLiteLibrary(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(!FileManager.default.fileExists(atPath: library.files.attachmentDirectory(for: removed.id).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedStagingFile.path))
        #expect(try await reopened.attachments(for: reference.id) == [missing])
        await #expect(throws: LibraryError.missingAttachmentFile(missing.originalFilename)) {
            try await reopened.attachmentFile(for: reference.id, attachmentID: missing.id)
        }
        let replacement = try await reopened.attachFile(at: source, to: reference.id)
        let available = try await reopened.attachmentFile(for: reference.id, attachmentID: replacement.id)
        #expect(try await reopened.attachmentFile(for: reference.id) == available)
    }
}

@Test func purgePackagesAvailableFilesAndReportsMissingAttachments() async throws {
    try await withTemporaryLibrary { library, directory in
        let reference = try await library.createReference(.init(
            citationKey: "LinearHaskell", entryType: "article", fields: ["title": "{Linear Haskell}"]
        ))
        let collection = try await library.createCollection(named: "Substructural types")
        try await library.setMembership(
            .init(collectionID: collection.id, referenceID: reference.id), isMember: true
        )
        let source = directory.appendingPathComponent("Linear Haskell.txt")
        let bytes = Data("Linear types and resource usage\n".utf8)
        try bytes.write(to: source)
        let first = try await library.attachFile(at: source, to: reference.id)
        let second = try await library.attachFile(at: source, to: reference.id)
        let missing = try await library.attachFile(at: source, to: reference.id)
        let missingPath = try await library.attachmentFile(for: reference.id, attachmentID: missing.id)
        try FileManager.default.removeItem(at: missingPath)

        await #expect(throws: LibraryError.referenceNotInTrash(reference.id)) {
            try await library.purgeReference(id: reference.id) { _ in throw TestFailure.handoff }
        }
        try await library.moveReferenceToTrash(id: reference.id)
        let recovery = directory.appendingPathComponent("Recovered")
        let result = try await library.purgeReference(id: reference.id) { package in
            #expect(package.lastPathComponent == "TinyRefs-\(reference.id.databaseKey)")
            try FileManager.default.moveItem(at: package, to: recovery)
            return recovery
        }
        #expect(result.recoveryURL == recovery)
        #expect(result.missingAttachments == [missing])
        let bibliography = try Data(contentsOf: recovery.appendingPathComponent("reference.bib"))
        #expect(try BibLaTeX.references(from: bibliography) == [reference.metadata])
        for attachment in [first, second] {
            let recovered = recovery.appending(path: "attachments/\(attachment.id.databaseKey)/\(source.lastPathComponent)")
            #expect(try Data(contentsOf: recovered) == bytes)
        }
        for attachment in [first, second, missing] {
            #expect(!FileManager.default.fileExists(atPath: library.files.attachmentDirectory(for: attachment.id).path))
        }
        #expect(try await library.reference(id: reference.id) == nil)
        #expect(try await library.attachments(for: reference.id).isEmpty)
        #expect(try await library.memberships(for: reference.id).isEmpty)
        #expect(try await library.collections() == [collection])
    }
}

@Test func purgeCanRetryAfterExportCopyAndHandoffFailures() async throws {
    try await withTemporaryLibrary { library, directory in
        let reference = try await library.createReference(.init(citationKey: "SystemT", entryType: "book"))
        let source = directory.appendingPathComponent("Notes.txt")
        let bytes = Data("Primitive recursion\n".utf8)
        try bytes.write(to: source)
        let attachment = try await library.attachFile(at: source, to: reference.id)
        let managed = try await library.attachmentFile(for: reference.id)
        try await library.moveReferenceToTrash(id: reference.id)

        // Simulate metadata saved by an older version that could not validate it.
        try await library.database.write { db in
            var row = try SQLiteLibrary.requireReference(reference.id, in: db)
            row.entryType = "preamble"
            try row.update(db)
        }
        await #expect(throws: BibLaTeX.BridgeError.self) {
            try await library.purgeReference(id: reference.id) { _ in throw TestFailure.handoff }
        }
        #expect(try await library.reference(id: reference.id)?.trashedAt != nil)
        #expect(try Data(contentsOf: managed) == bytes)
        try await library.database.write { db in
            var row = try SQLiteLibrary.requireReference(reference.id, in: db)
            row.entryType = reference.metadata.entryType
            try row.update(db)
        }

        let displaced = directory.appendingPathComponent("Displaced")
        try FileManager.default.moveItem(at: managed, to: displaced)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        await #expect(throws: LibraryError.invalidManagedPath(managed.path)) {
            try await library.purgeReference(id: reference.id) { _ in throw TestFailure.handoff }
        }
        #expect(try await library.reference(id: reference.id)?.trashedAt != nil)
        try FileManager.default.removeItem(at: managed)
        try FileManager.default.moveItem(at: displaced, to: managed)

        await #expect(throws: TestFailure.handoff) {
            try await library.purgeReference(id: reference.id) { _ in throw TestFailure.handoff }
        }
        #expect(try await library.reference(id: reference.id)?.trashedAt != nil)
        #expect(try await library.attachments(for: reference.id) == [attachment])
        #expect(try Data(contentsOf: managed) == bytes)

        let reopened = try SQLiteLibrary(directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: reopened.files.staging.path).isEmpty)
        let recovery = directory.appendingPathComponent("Recovered")
        _ = try await reopened.purgeReference(id: reference.id) { package in
            try FileManager.default.moveItem(at: package, to: recovery)
            return recovery
        }
        #expect(try await reopened.reference(id: reference.id) == nil)
    }
}

@Test func failedPurgeCommitLeavesTheReferenceRestorableAfterHandoff() async throws {
    try await withTemporaryLibrary { library, directory in
        let reference = try await library.createReference(.init(citationKey: "SystemT", entryType: "book"))
        let source = directory.appendingPathComponent("Notes.txt")
        let bytes = Data("Primitive recursion\n".utf8)
        try bytes.write(to: source)
        let attachment = try await library.attachFile(at: source, to: reference.id)
        let managed = try await library.attachmentFile(for: reference.id)
        try await library.moveReferenceToTrash(id: reference.id)

        let observer = RejectCommit()
        try await library.database.writeWithoutTransaction { db in
            db.add(transactionObserver: observer, extent: .nextTransaction)
        }
        let recovery = directory.appendingPathComponent("Recovered")
        await #expect(throws: TestFailure.commit) {
            try await library.purgeReference(id: reference.id) { package in
                try FileManager.default.moveItem(at: package, to: recovery)
                return recovery
            }
        }
        #expect(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("reference.bib").path))
        #expect(try await library.reference(id: reference.id)?.trashedAt != nil)
        #expect(try await library.attachments(for: reference.id) == [attachment])
        #expect(try Data(contentsOf: managed) == bytes)

        try await library.restoreReference(id: reference.id)
        #expect(try await library.reference(id: reference.id) == reference)
    }
}

private enum TestFailure: Error {
    case handoff, commit
}

private final class RejectCommit: TransactionObserver, Sendable {
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { throw TestFailure.commit }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}
