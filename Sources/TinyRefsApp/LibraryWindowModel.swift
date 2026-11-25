import Foundation
import Observation
import TinyRefs

typealias LibraryStore = ReferenceStore & CollectionStore & AttachmentStore

@MainActor @Observable
final class LibraryWindowModel {
    struct Query: Equatable {
        let scope: ReferenceScope
        let search: String
        let revision: Int
    }

    struct DetailsRequest: Equatable {
        let id: UUID?
        let revision: Int
    }

    struct Details {
        let row: ReferenceRow
        let collectionIDs: Set<UUID>
        let attachments: [AttachmentRecord]
        var reference: BibliographicReference { row.reference }
    }

    struct CollectionNode: Identifiable {
        let collection: LibraryCollection
        let children: [CollectionNode]
        var id: UUID { collection.id }
    }

    var store: (any LibraryStore)?
    var opening = false
    var startupError: String?
    var working = false
    var revision = 0
    var collections: [LibraryCollection] = []
    var tableRows: [ReferenceRow] = []
    var details: Details?
    var previewableReferences: Set<UUID> = []
    var notice: WindowNotice?
    var editor: LibraryEditor?
    var confirmation: LibraryConfirmation?
    var filePicker: LibraryFilePicker?
    var bibliographyDocument: BibliographyDocument?
    var showsBibliographyExporter = false

    var showsNavigator = true
    var showsInspector = true
    var referenceSearchRequest = 0
    var tableScope: ReferenceScope = .library
    var tableSearch = ""
    var tableSelection: Set<UUID> = []
    var tableSort = [KeyPathComparator(\ReferenceRow.title, comparator: .localizedStandard)]
    var expandedCollections: Set<UUID> = []

    init(store: (any LibraryStore)? = nil) { self.store = store }

    var tableQuery: Query { Query(scope: tableScope, search: tableSearch, revision: revision) }
    var detailsRequest: DetailsRequest { DetailsRequest(id: inspectedReferenceID, revision: revision) }
    var selectedReference: BibliographicReference? { selectedRow?.reference }
    var selectedRow: ReferenceRow? {
        guard let id = inspectedReferenceID else { return nil }
        if let details, details.row.id == id { return details.row }
        return tableRows.first(where: { $0.id == id })
    }
    private var inspectedReferenceID: UUID? {
        tableSelection.count == 1 ? tableSelection.first : nil
    }
    var collectionTree: [CollectionNode] {
        let groups = Dictionary(grouping: collections, by: \.parentID)
        func nodes(under id: UUID?) -> [CollectionNode] {
            (groups[id] ?? []).map { CollectionNode(collection: $0, children: nodes(under: $0.id)) }
        }
        return nodes(under: nil)
    }

    func open(directory: URL) async {
        guard store == nil, !opening else { return }
        opening = true
        startupError = nil
        defer { opening = false }
        do {
            store = try await Task.detached { try SQLiteLibrary(directory: directory) }.value
        } catch {
            startupError = error.localizedDescription
        }
    }

    func loadCollections() async {
        guard let store else { return }
        do {
            let updated = try await store.collections()
            try Task.checkCancellation()
            collections = updated
            if let id = tableScope.collectionID, !updated.contains(where: { $0.id == id }) {
                selectScope(.library)
            }
        } catch { report(error) }
    }

    func loadTable(_ query: Query) async {
        guard let store else { return }
        do {
            if !query.search.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            let references = try await store.references(in: query.scope, matching: query.search)
            try Task.checkCancellation()
            let rows = try await ReferenceRow.prepare(references)
            try Task.checkCancellation()
            guard query == tableQuery else { return }
            tableRows = rows
            tableSelection.formIntersection(rows.map(\.id))
        } catch { report(error) }
    }

    func loadDetails(_ request: DetailsRequest) async {
        guard let id = request.id, let store else {
            details = nil
            return
        }
        if details?.reference.id != id { details = nil }
        do {
            guard let reference = try await store.reference(id: id) else {
                if request == detailsRequest { details = nil }
                return
            }
            async let memberships = store.memberships(for: id)
            async let attachments = store.attachments(for: id)
            let row = try ReferenceRow(reference, BibLaTeX.structuredFields(for: reference.metadata))
            let result = try await Details(
                row: row,
                collectionIDs: Set(memberships.map(\.collectionID)),
                attachments: attachments
            )
            try Task.checkCancellation()
            if request == detailsRequest { details = result }
        } catch { report(error) }
    }

    func selectScope(_ scope: ReferenceScope) {
        guard tableScope != scope else { return }
        tableScope = scope
        tableSelection = []
        tableRows = []
    }

    func setExpanded(_ expanded: Bool, collectionID: UUID) {
        if expanded { expandedCollections.insert(collectionID) } else { expandedCollections.remove(collectionID) }
    }

    func canParentCollection(_ collectionID: UUID, under parentID: UUID) -> Bool {
        var ancestorID: UUID? = parentID
        var visited: Set<UUID> = [collectionID]
        while let id = ancestorID {
            guard visited.insert(id).inserted,
                  let ancestor = collections.first(where: { $0.id == id }) else { return false }
            ancestorID = ancestor.parentID
        }
        return true
    }

    func report(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        notice = WindowNotice(title: "TinyRefs", message: error.localizedDescription)
    }

    func perform<T>(_ operation: (any LibraryStore) async throws -> T) async throws -> T {
        guard let store else { throw WindowError.libraryUnavailable }
        guard !working else { throw WindowError.libraryBusy }
        working = true
        defer {
            working = false
            revision += 1
        }
        return try await operation(store)
    }

    func run(_ operation: @escaping @MainActor (any LibraryStore) async throws -> Void) {
        Task {
            do { try await perform(operation) } catch { report(error) }
        }
    }
}

extension ReferenceScope {
    var collectionID: UUID? {
        if case .collection(let id) = self { return id }
        return nil
    }
    var allowsImport: Bool { self != .trash }
}

struct WindowNotice {
    let title: String
    let message: String
}

enum WindowError: LocalizedError {
    case libraryUnavailable, libraryBusy
    case duplicateField(String), incompleteField, expectedSingleReference, noAvailablePDF, cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable: "The library is unavailable."
        case .libraryBusy: "Wait for the current library operation to finish."
        case .duplicateField(let name): "The field '\(name)' appears more than once."
        case .incompleteField: "Enter a name and a BibLaTeX expression for each field."
        case .expectedSingleReference: "Enter one BibTeX entry to create a reference."
        case .noAvailablePDF: "The reference has no available PDF."
        case .cannotOpen(let name): "macOS could not open '\(name)'."
        }
    }
}
