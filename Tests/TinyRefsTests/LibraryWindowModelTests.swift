import Foundation
import Testing
import TinyRefs
@testable import TinyRefsApp

@Test func movingCollectionsPreservesTheirContentsAndRejectsInvalidDrops() async throws {
    try await withTemporaryLibrary { @MainActor library, _ in
        let source = try await library.createCollection(named: "Source")
        let child = try await library.createCollection(named: "Child", parentID: source.id)
        let target = try await library.createCollection(named: "Target")
        let reference = try await library.createReference(.init(citationKey: "SystemT", entryType: "book"))
        let membership = CollectionMembership(collectionID: source.id, referenceID: reference.id)
        try await library.setMembership(membership, isMember: true)

        let model = LibraryWindowModel(store: library)
        await model.loadCollections()
        model.selectScope(.collection(source.id))
        let drag = CollectionDrag(collectionID: source.id)
        #expect(!model.dropCollection(drag, into: source.id))
        #expect(!model.dropCollection(drag, into: child.id))
        #expect(!model.dropCollection(drag, into: nil))

        try await model.moveCollection(id: source.id, to: target.id)
        await model.loadCollections()
        #expect(model.expandedCollections.contains(target.id))
        #expect(model.tableScope == .collection(source.id))
        #expect(model.collectionTree.first?.children.first?.id == source.id)
        #expect(!model.dropCollection(drag, into: target.id))

        try await model.moveCollection(id: source.id, to: nil)
        await model.loadCollections()
        #expect(model.collectionTree.first?.id == source.id)
        #expect(model.collectionTree.first?.children.map(\.id) == [child.id])
        #expect(try await library.memberships(for: reference.id) == [membership])
    }
}

@Test(arguments: [false, true])
func newReferenceAppearsSelectedInUnfiledItems(fromBibTeX: Bool) async throws {
    try await withTemporaryLibrary { @MainActor library, _ in
        let model = LibraryWindowModel(store: library)
        model.selectScope(.trash)
        model.tableSearch = "Previous search"
        model.showsInspector = false

        let metadata = ReferenceMetadata(citationKey: "SystemT", entryType: "book", fields: ["title": "{System T}"])
        if fromBibTeX {
            try await model.createReference(fromBibTeX: BibLaTeX.serialize(metadata))
        } else {
            try await model.createReference(metadata)
        }

        let references = try await library.references(in: .unfiled)
        #expect(references.map(\.metadata) == [metadata])
        #expect(model.tableScope == .unfiled)
        #expect(model.tableSearch.isEmpty)
        #expect(model.showsInspector)
        await model.loadTable(model.tableQuery)
        #expect(model.selectedReference == references.first)
    }
}

@Test func fullLibraryExportIgnoresScopeAndSearchAndExcludesTrash() async throws {
    try await withTemporaryLibrary { @MainActor library, _ in
        let collection = try await library.createCollection(named: "Type systems")
        let collected = try await library.createReference(ReferenceMetadata(citationKey: "SystemT", entryType: "book"))
        try await library.setMembership(.init(collectionID: collection.id, referenceID: collected.id), isMember: true)
        let unfiled = try await library.createReference(ReferenceMetadata(citationKey: "SystemF", entryType: "article"))
        let trashed = try await library.createReference(ReferenceMetadata(citationKey: "Old", entryType: "misc"))
        try await library.moveReferenceToTrash(id: trashed.id)

        let model = LibraryWindowModel(store: library)
        model.selectScope(.collection(collection.id))
        model.tableSearch = "SystemT"
        await model.exportBibliography()

        let document = try #require(model.bibliographyDocument)
        #expect(model.showsBibliographyExporter)
        #expect(document.filename == "Library.bib")
        #expect(try BibLaTeX.references(from: document.data) == [unfiled.metadata, collected.metadata])
    }
}

@Test func collectionExportUsesTheRequestedCollectionsActiveDirectMembers() async throws {
    try await withTemporaryLibrary { @MainActor library, _ in
        let collection = try await library.createCollection(named: "Types/Logic")
        let child = try await library.createCollection(named: "Logic", parentID: collection.id)
        let directEntries = Data("@book{SystemT,} @book{Old,}".utf8)
        let entries = try await library.importBibLaTeX(directEntries, into: collection.id)
        let trashed = try #require(entries.last)
        try await library.moveReferenceToTrash(id: trashed.id)
        try await library.importBibLaTeX(Data("@book{ChildOnly,}".utf8), into: child.id)

        let model = LibraryWindowModel(store: library)
        await model.loadCollections()
        model.selectScope(.collection(child.id))
        model.tableSearch = "Unrelated search"
        #expect(model.selectedCollection == child)
        await model.exportBibliography(.collection(collection))

        let document = try #require(model.bibliographyDocument)
        #expect(model.showsBibliographyExporter)
        #expect(document.filename == "Types-Logic.bib")
        #expect(try BibLaTeX.references(from: document.data).map(\.citationKey) == ["SystemT"])
    }
}

@Test func selectedExportPreservesFieldsAndSearchPrunesSelection() async throws {
    try await withTemporaryLibrary { @MainActor library, _ in
        let systemT = try await library.createReference(ReferenceMetadata(
            citationKey: "SystemT", entryType: "book", fields: ["custom": "{{System T} notes}"]
        ))
        let systemF = try await library.createReference(ReferenceMetadata(citationKey: "SystemF", entryType: "article"))
        try await library.createReference(ReferenceMetadata(citationKey: "Other", entryType: "misc"))

        let model = LibraryWindowModel(store: library)
        await model.loadTable(model.tableQuery)
        model.tableSelection = [systemT.id, systemF.id]
        #expect(model.selectedReference == nil)

        let selection = model.tableRows.filter { model.tableSelection.contains($0.id) }.map(\.reference)
        await model.exportBibliography(.selection(selection))

        let document = try #require(model.bibliographyDocument)
        #expect(model.showsBibliographyExporter)
        #expect(document.filename == "References.bib")
        #expect(try BibLaTeX.references(from: document.data) == [systemF.metadata, systemT.metadata])

        model.tableSearch = "SystemT"
        await model.loadTable(model.tableQuery)
        #expect(model.tableSelection == [systemT.id])
        #expect(model.selectedReference == systemT)

        model.selectScope(.trash)
        #expect(model.tableSelection.isEmpty)
    }
}
