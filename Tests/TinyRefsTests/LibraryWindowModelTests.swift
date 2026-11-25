import Foundation
import Testing
import TinyRefs
@testable import TinyRefsApp

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
        await model.exportBibliography(selection)

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
