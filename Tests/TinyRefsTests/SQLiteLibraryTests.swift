import Foundation
import GRDB
import Testing
@testable import TinyRefs

@Test func bibliographyRoundTripPreservesMetadataAndExportsActiveCollectionMembers() async throws {
    try await withTemporaryLibrary { source, directory in
        let fixture = try #require(Bundle.module.url(
            forResource: "Haskell", withExtension: "bib", subdirectory: "Fixtures"
        ))
        let collection = try await source.createCollection(named: "Functional programming")
        let imported = try await source.importBibLaTeX(Data(contentsOf: fixture), into: collection.id)
        #expect(imported.map(\.metadata.citationKey) == ["Jones1992", "Vytiniotis2011", "Bernardy2017"])
        let linearHaskell = try #require(imported.last)
        #expect(linearHaskell.metadata.fields["month"] == "{December}")
        #expect(linearHaskell.metadata.fields["issue_date"] == "{January 2018}")
        for reference in imported {
            #expect(try await source.memberships(for: reference.id) == [
                CollectionMembership(collectionID: collection.id, referenceID: reference.id),
            ])
        }
        let unfiled = try await source.createReference(ReferenceMetadata(citationKey: "SystemT", entryType: "book"))

        try await source.moveReferenceToTrash(id: linearHaskell.id)
        let active = try await source.exportBibLaTeX(fromCollection: collection.id)
        #expect(try BibLaTeX.references(from: Data(active.utf8)).map(\.citationKey) == ["Jones1992", "Vytiniotis2011"])
        let wholeLibrary = try await source.exportBibLaTeX()
        let activeKeys = try BibLaTeX.references(from: Data(wholeLibrary.utf8)).map(\.citationKey)
        #expect(activeKeys.contains(unfiled.metadata.citationKey))
        #expect(!activeKeys.contains(linearHaskell.metadata.citationKey))

        let archived = try await source.reference(id: linearHaskell.id)
        let recovery = try BibLaTeX.serialize(#require(archived).metadata)
        #expect(try BibLaTeX.references(from: Data(recovery.utf8)) == [linearHaskell.metadata])
        try await source.restoreReference(id: linearHaskell.id)

        let exported = try await source.exportBibLaTeX(fromCollection: collection.id)
        let destination = try SQLiteLibrary(directory: directory.appendingPathComponent("Round trip", isDirectory: true))
        let reimported = try await destination.importBibLaTeX(Data(exported.utf8))
        #expect(reimported.map(\.metadata) == imported.map(\.metadata).sorted { $0.citationKey < $1.citationKey })
        #expect(Set(reimported.map(\.id)).isDisjoint(with: imported.map(\.id)))
        #expect(try await destination.references(in: .unfiled) == reimported)
    }
}

@Test func bibliographyImportRollsBackOnDuplicateOrMalformedEntries() async throws {
    try await withTemporaryLibrary { library, _ in
        let collection = try await library.createCollection(named: "Type systems")
        let reserved = try await library.createReference(ReferenceMetadata(citationKey: "SystemT", entryType: "book"))
        try await library.moveReferenceToTrash(id: reserved.id)

        let existingConflict = Data("@book{SystemF,} @book{SystemT,}".utf8)
        await #expect(throws: LibraryError.duplicateCitationKey("SystemT")) {
            try await library.importBibLaTeX(existingConflict, into: collection.id)
        }

        for text in [
            "@book{SystemF,} @article{SystemF,}",
            "@book{SystemF,} @article{LinearHaskell, title = {Linear Haskell}",
            "@article{LinearHaskell, title = {Linear Haskell}, TITLE = {Duplicate}}",
        ] {
            await #expect(throws: BibLaTeX.BridgeError.self) {
                try await library.importBibLaTeX(Data(text.utf8), into: collection.id)
            }
        }
        let missingCollection = UUID()
        await #expect(throws: LibraryError.collectionNotFound(missingCollection)) {
            try await library.importBibLaTeX(Data("@book{SystemF,}".utf8), into: missingCollection)
        }
        #expect(try await library.references(in: .library).isEmpty)
        #expect(try await library.references(in: .collection(collection.id)).isEmpty)
        #expect(try await library.references(in: .trash).map(\.id) == [reserved.id])
        #expect(try await library.database.read { try MembershipRow.fetchCount($0) } == 0)
    }
}

@Test func invalidBibLaTeXMetadataCannotBeCreatedOrSaved() async throws {
    try await withTemporaryLibrary { library, _ in
        let valid = ReferenceMetadata(citationKey: "SystemT", entryType: "book", fields: ["title": "{System T}"])
        var invalid = valid
        invalid.citationKey = "System T"
        await #expect(throws: BibLaTeX.BridgeError.self) {
            try await library.createReference(invalid)
        }
        #expect(try await library.references(in: .library).isEmpty)

        let reference = try await library.createReference(valid)
        for changes in [
            ReferenceChanges(entryType: "preamble"),
            ReferenceChanges(fields: ["full title": "{Gödel’s System T}"]),
            ReferenceChanges(fields: ["title": "{Gödel’s System T"]),
            ReferenceChanges(fields: ["title": "undefinedMacro"]),
        ] {
            await #expect(throws: BibLaTeX.BridgeError.self) {
                try await library.updateReference(id: reference.id, changes: changes)
            }
        }
        await #expect(throws: BibLaTeX.BridgeError.self) {
            try await library.updateReference(id: reference.id, metadata: invalid)
        }
        #expect(try await library.reference(id: reference.id) == reference)
    }
}

@Test func libraryDirectoryKeepsTheDatabaseAndAttachmentsTogether() async throws {
    try await withTemporaryLibrary { defaultLibrary, directory in
        let selected = directory.appendingPathComponent("Gödel library", isDirectory: true)
        let library = try SQLiteLibrary(directory: selected)
        let reference = try await library.createReference(ReferenceMetadata(citationKey: "SystemT", entryType: "book"))

        let reopened = try SQLiteLibrary(directory: selected)
        #expect(FileManager.default.fileExists(atPath: selected.appendingPathComponent("library.sqlite").path))
        let attachments = selected.appendingPathComponent("attachments", isDirectory: true)
        #expect(try attachments.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try await reopened.reference(id: reference.id) == reference)
        #expect(try await defaultLibrary.references(in: .library).isEmpty)
    }
}

@Test func keyEditsPreserveIdentityAndMetadataAcrossReopening() async throws {
    try await withTemporaryLibrary { library, directory in
        let store: any ReferenceStore = library
        let reference = try await store.createReference(ReferenceMetadata(
            citationKey: "HindleyMilnerDraft",
            entryType: "CustomEntry",
            fields: ["Title": "{{ML} principal type schemes}", "Note": "{}", "PrivateField": "{type schemes}"]
        ))
        #expect(reference.metadata.entryType == "customentry")
        #expect(reference.metadata.fields["title"] == "{{ML} principal type schemes}")
        #expect(reference.metadata.fields["note"] == "{}")

        let collection = try await library.createCollection(named: "Type inference")
        let membership = CollectionMembership(collectionID: collection.id, referenceID: reference.id)
        try await library.setMembership(membership, isMember: true)

        var metadata = reference.metadata
        metadata.citationKey = "DamasMilner1982"
        metadata.fields.removeValue(forKey: "note")
        let edited = try await store.updateReference(id: reference.id, metadata: metadata)
        #expect(edited.id == reference.id)

        let reopened = try SQLiteLibrary(directory: directory)
        #expect(try await reopened.reference(id: reference.id) == edited)
        #expect(try await reopened.memberships(for: reference.id) == [membership])
        #expect(edited.metadata.fields == ["title": "{{ML} principal type schemes}", "privatefield": "{type schemes}"])
        try await reopened.createReference(ReferenceMetadata(citationKey: "HindleyMilnerDraft", entryType: "book"))
    }
}

@Test func citationKeysUseExactCaseAndStayReservedInTrash() async throws {
    try await withTemporaryLibrary { library, _ in
        let upper = try await library.createReference(ReferenceMetadata(citationKey: "SystemF", entryType: "book"))
        let lower = try await library.createReference(ReferenceMetadata(
            citationKey: "systemf", entryType: "article", fields: ["title": "{Polymorphic lambda calculus}"]
        ))
        try await library.moveReferenceToTrash(id: upper.id)
        let trashed = try await library.reference(id: upper.id)
        #expect(trashed?.trashedAt != nil)

        try await library.moveReferenceToTrash(id: upper.id)
        #expect(try await library.reference(id: upper.id) == trashed)
        await #expect(throws: LibraryError.duplicateCitationKey("SystemF")) {
            try await library.createReference(upper.metadata)
        }
        await #expect(throws: LibraryError.duplicateCitationKey("SystemF")) {
            try await library.updateReference(id: lower.id, metadata: upper.metadata)
        }
        await #expect(throws: LibraryError.referenceInTrash(upper.id)) {
            try await library.updateReference(id: upper.id, metadata: upper.metadata)
        }
        #expect(try await library.reference(id: lower.id) == lower)

        try await library.restoreReference(id: upper.id)
        #expect(try await library.reference(id: upper.id) == upper)
    }
}

@Test func concurrentWritersCannotReserveTheSameCitationKey() async throws {
    try await withTemporaryLibrary { first, directory in
        let second = try SQLiteLibrary(directory: directory)
        let metadata = ReferenceMetadata(citationKey: "Plotkin1975", entryType: "article")

        @Sendable func attemptInsert(in store: any ReferenceStore) async throws -> Bool {
            do {
                try await store.createReference(metadata)
                return true
            } catch LibraryError.duplicateCitationKey("Plotkin1975") {
                return false
            }
        }

        async let firstResult = attemptInsert(in: first)
        async let secondResult = attemptInsert(in: second)
        let results = try await [firstResult, secondResult]
        #expect(results.count(where: { $0 }) == 1)
        #expect(try await second.references(in: .library).count == 1)
    }
}

@Test func concurrentPartialEditsKeepChangesFromBothWriters() async throws {
    try await withTemporaryLibrary { first, directory in
        let second = try SQLiteLibrary(directory: directory)
        let reference = try await first.createReference(ReferenceMetadata(
            citationKey: "SystemT", entryType: "book", fields: ["note": "{Early draft}"]
        ))
        async let title = first.updateReference(id: reference.id, changes: ReferenceChanges(
            fields: ["TITLE": "{Primitive recursion}"], removedFields: ["Note"]
        ))
        async let author = second.updateReference(id: reference.id, changes: ReferenceChanges(
            fields: ["author": "{Gödel, Kurt}"]
        ))
        _ = try await (title, author)

        let edited = try await first.reference(id: reference.id)
        #expect(edited?.metadata.fields == [
            "title": "{Primitive recursion}", "author": "{Gödel, Kurt}",
        ])
    }
}

@Test func searchRespectsScopeAndTreatsTextAsLiteral() async throws {
    try await withTemporaryLibrary { library, _ in
        let reader: any ReferenceReader = library
        let filed = try await library.createReference(ReferenceMetadata(
            citationKey: "SystemT",
            entryType: "article",
            fields: ["title": "{Primitive recursion with %_ metavariables}", "author": "{Gödel, Kurt}"]
        ))
        let loose = try await library.createReference(ReferenceMetadata(citationKey: "SystemF", entryType: "book"))
        let collection = try await library.createCollection(named: "Gödel’s System T")
        try await library.setMembership(
            CollectionMembership(collectionID: collection.id, referenceID: filed.id), isMember: true
        )

        #expect(try await reader.references(in: .library, matching: "systemt") == [filed])
        #expect(try await reader.references(in: .collection(collection.id), matching: "GÖDEL") == [filed])
        #expect(try await reader.references(in: .library, matching: "%_") == [filed])
        #expect(try await reader.references(in: .library, matching: "' OR 1=1 --").isEmpty)
        #expect(try await reader.references(in: .unfiled, matching: nil) == [loose])

        try await library.moveReferenceToTrash(id: filed.id)
        #expect(try await reader.references(in: .collection(collection.id), matching: nil).isEmpty)
        #expect(try await reader.references(in: .library, matching: "gödel").isEmpty)
        #expect(try await reader.references(in: .trash, matching: "gödel").map(\.id) == [filed.id])
    }
}

@Test func membershipSurvivesTrashAndUnfiledReflectsSurvivingCollections() async throws {
    try await withTemporaryLibrary { library, _ in
        let store: any CollectionStore = library
        let reference = try await library.createReference(ReferenceMetadata(citationKey: "Parametricity", entryType: "article"))
        let first = try await store.createCollection(named: "Type systems", parentID: nil)
        let second = try await store.createCollection(named: "Semantics", parentID: nil)
        let memberOfFirst = CollectionMembership(collectionID: first.id, referenceID: reference.id)
        let memberOfSecond = CollectionMembership(collectionID: second.id, referenceID: reference.id)
        #expect(try await library.references(in: .unfiled) == [reference])
        try await store.setMembership(memberOfFirst, isMember: true)
        try await store.setMembership(memberOfFirst, isMember: true)
        try await store.setMembership(memberOfSecond, isMember: true)
        #expect(try await store.memberships(for: reference.id).count == 2)
        #expect(try await library.references(in: .unfiled).isEmpty)

        try await library.moveReferenceToTrash(id: reference.id)
        #expect(try await store.memberships(for: reference.id).count == 2)
        await #expect(throws: LibraryError.referenceInTrash(reference.id)) {
            try await store.setMembership(memberOfSecond, isMember: false)
        }
        try await store.deleteCollection(id: first.id)
        try await library.restoreReference(id: reference.id)
        #expect(try await store.memberships(for: reference.id) == [memberOfSecond])
        #expect(try await library.references(in: .collection(second.id)) == [reference])
        #expect(try await library.references(in: .unfiled).isEmpty)

        try await store.setMembership(memberOfSecond, isMember: false)
        try await store.setMembership(memberOfSecond, isMember: false)
        #expect(try await library.references(in: .unfiled) == [reference])

        try await store.setMembership(memberOfSecond, isMember: true)
        try await library.moveReferenceToTrash(id: reference.id)
        try await store.deleteCollection(id: second.id)
        try await library.restoreReference(id: reference.id)
        #expect(try await library.references(in: .unfiled) == [reference])
    }
}

@Test func nestedCollectionsPreserveCaseSensitiveNamesAndRejectCycles() async throws {
    try await withTemporaryLibrary { library, _ in
        let root = try await library.createCollection(named: "Gödel")
        let other = try await library.createCollection(named: "gödel")
        let child = try await library.createCollection(named: "Inference", parentID: root.id)
        let grandchild = try await library.createCollection(named: "Type systems", parentID: child.id)
        let reference = try await library.createReference(ReferenceMetadata(
            citationKey: "DunfieldKrishnaswami2013", entryType: "article"
        ))
        let membership = CollectionMembership(collectionID: child.id, referenceID: reference.id)
        try await library.setMembership(membership, isMember: true)

        await #expect(throws: LibraryError.duplicateCollectionName("Inference")) {
            try await library.createCollection(named: "Inference", parentID: other.id)
        }
        await #expect(throws: LibraryError.duplicateCollectionName("Type systems")) {
            try await library.renameCollection(id: child.id, to: "Type systems")
        }
        await #expect(throws: LibraryError.blankCollectionName) {
            try await library.createCollection(named: " \n\t")
        }
        let missingParent = UUID()
        await #expect(throws: LibraryError.collectionNotFound(missingParent)) {
            try await library.moveCollection(id: child.id, to: missingParent)
        }
        await #expect(throws: LibraryError.collectionCycle(root.id)) {
            try await library.moveCollection(id: root.id, to: grandchild.id)
        }
        await #expect(throws: LibraryError.collectionCycle(child.id)) {
            try await library.moveCollection(id: child.id, to: child.id)
        }
        #expect(try await library.collections() == [root, child, grandchild, other])

        try await library.renameCollection(id: child.id, to: "Bidirectional typing")
        try await library.moveCollection(id: child.id, to: other.id)
        let moved = LibraryCollection(id: child.id, name: "Bidirectional typing", parentID: other.id)
        #expect(try await library.collections() == [moved, root, grandchild, other])
        #expect(try await library.references(in: .collection(other.id)).isEmpty)
        #expect(try await library.references(in: .collection(child.id)) == [reference])

        try await library.deleteCollection(id: other.id)
        let promoted = LibraryCollection(id: child.id, name: "Bidirectional typing")
        #expect(try await library.collections() == [promoted, root, grandchild])
        #expect(try await library.memberships(for: reference.id) == [membership])

        try await library.moveCollection(id: child.id, to: root.id)
        try await library.moveCollection(id: child.id, to: nil)
        #expect(try await library.collections() == [promoted, root, grandchild])
    }
}

@Test func deletingAReferenceCascadesToFieldsAttachmentsAndMemberships() async throws {
    try await withTemporaryLibrary { library, _ in
        let reference = try await library.createReference(ReferenceMetadata(
            citationKey: "LinearHaskell", entryType: "article", fields: ["title": "{Linear Haskell}"]
        ))
        let collection = try await library.createCollection(named: "Substructural types")
        let membership = CollectionMembership(collectionID: collection.id, referenceID: reference.id)
        try await library.setMembership(membership, isMember: true)
        let attachmentID = UUID()
        let row = AttachmentRow(
            id: attachmentID,
            referenceID: reference.id,
            relativePath: "attachments/\(attachmentID.uuidString.lowercased())/document.pdf",
            originalFilename: "Linear Haskell.pdf"
        )
        try await library.database.write { db in
            try row.insert(db)
            let storedID = try ReferenceRow.select(ReferenceRow.CodingKeys.id, as: String.self).fetchOne(db)
            #expect(storedID == reference.id.uuidString.lowercased())
        }

        try await library.moveReferenceToTrash(id: reference.id)
        #expect(try await library.attachments(for: reference.id) == [row.attachment])
        #expect(try await library.memberships(for: reference.id) == [membership])

        // This is a schema test. The application will delete rows after the Trash handoff.
        try await library.database.write { db in
            let deleted = try ReferenceRow.deleteOne(db, key: reference.id.databaseKey)
            #expect(deleted)
            #expect(try ReferenceFieldRow.fetchCount(db) == 0)
            #expect(try AttachmentRow.fetchCount(db) == 0)
            #expect(try MembershipRow.fetchCount(db) == 0)
        }
        #expect(try await library.collections() == [collection])
        #expect(try await library.reference(id: reference.id) == nil)
    }
}

private func withTemporaryLibrary(
    _ body: (SQLiteLibrary, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TinyRefsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary library: \(error)")
        }
    }
    try await body(SQLiteLibrary(directory: directory), directory)
}
