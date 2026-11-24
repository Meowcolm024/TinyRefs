import Foundation
import Observation
import OSLog
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
        let reference: BibliographicReference
        let collectionIDs: Set<UUID>
        let attachments: [AttachmentRecord]
    }

    struct CollectionNode: Identifiable {
        let collection: LibraryCollection
        let children: [CollectionNode]
        var id: UUID { collection.id }
    }

    enum SidebarSelection: Hashable {
        case scope(ReferenceScope)
        case reference(UUID, ReferenceScope)
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

    var showsNavigator = true
    var showsInspector = true
    var referenceSearchRequest = 0
    var tableScope: ReferenceScope = .library
    var tableSearch = ""
    var tableSelection: UUID?
    var tableSort = [KeyPathComparator(\ReferenceRow.title, comparator: .localizedStandard)]
    var reader: PDFSession?
    var readerScope: ReferenceScope = .library
    var readerSearch = ""
    var readerSelection: UUID?
    var expandedCollections: Set<UUID> = []
    var expandedReaderScopes: Set<ReferenceScope> = []
    @ObservationIgnored private var readerRequest = UUID()

    init(store: (any LibraryStore)? = nil) { self.store = store }

    var currentScope: ReferenceScope { reader == nil ? tableScope : readerScope }
    var selectedID: UUID? { reader == nil ? tableSelection : readerSelection }
    var search: String {
        get { reader == nil ? tableSearch : readerSearch }
        set {
            if reader == nil { tableSearch = newValue } else { readerSearch = newValue }
        }
    }
    var sidebarSelection: SidebarSelection {
        if reader != nil, let readerSelection { return .reference(readerSelection, readerScope) }
        return .scope(currentScope)
    }
    var tableQuery: Query { Query(scope: tableScope, search: tableSearch, revision: revision) }
    var detailsRequest: DetailsRequest { DetailsRequest(id: selectedID, revision: revision) }
    var selectedReference: BibliographicReference? {
        guard let id = selectedID else { return nil }
        if details?.reference.id == id { return details?.reference }
        if reader?.reference.id == id { return reader?.reference }
        return tableRows.first(where: { $0.id == id })?.reference
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
                tableScope = .library
                tableSelection = nil
            }
            if let id = readerScope.collectionID, !updated.contains(where: { $0.id == id }) {
                readerScope = .library
                readerSelection = nil
                expandedReaderScopes.insert(.library)
            }
        } catch { report(error) }
    }

    func loadTable(_ query: Query) async {
        do {
            let references = try await fetchReferences(query)
            guard query == tableQuery else { return }
            tableRows = references.map(ReferenceRow.init)
            if let tableSelection, !tableRows.contains(where: { $0.id == tableSelection }) {
                self.tableSelection = nil
            }
        } catch { report(error) }
    }

    func fetchReferences(_ query: Query) async throws -> [BibliographicReference] {
        guard let store else { return [] }
        if !query.search.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
        let result = try await store.references(in: query.scope, matching: query.search)
        try Task.checkCancellation()
        return result
    }

    func loadDetails(_ request: DetailsRequest) async {
        guard let id = request.id, let store else {
            details = nil
            return
        }
        if details?.reference.id != id { details = nil }
        do {
            guard let reference = try await store.reference(id: id) else {
                if request == detailsRequest {
                    details = nil
                    if reader?.reference.id == id { closePDF() }
                }
                return
            }
            async let memberships = store.memberships(for: id)
            async let attachments = store.attachments(for: id)
            let result = try await Details(
                reference: reference,
                collectionIDs: Set(memberships.map(\.collectionID)),
                attachments: attachments
            )
            try Task.checkCancellation()
            if request == detailsRequest { details = result }
        } catch { report(error) }
    }

    func refreshPDFAvailability(for id: UUID) async {
        guard let store else { return }
        let requestedRevision = revision
        do {
            let attachments = try await store.attachments(for: id).filter(\.isPDF)
            var available = false
            for attachment in attachments {
                do {
                    _ = try await store.attachmentFile(for: id, attachmentID: attachment.id)
                    available = true
                    break
                } catch LibraryError.missingAttachmentFile {
                    continue
                }
            }
            guard !Task.isCancelled, requestedRevision == revision else { return }
            if available { previewableReferences.insert(id) } else { previewableReferences.remove(id) }
        } catch {
            guard !Task.isCancelled, requestedRevision == revision else { return }
            previewableReferences.remove(id)
            Logger(subsystem: "org.tinyrefs.app", category: "Attachments")
                .debug("Could not check PDF availability: \(error.localizedDescription)")
        }
    }

    func select(_ selection: SidebarSelection) {
        switch selection {
        case .scope(let scope):
            if reader == nil {
                if tableScope != scope {
                    tableScope = scope
                    tableSelection = nil
                    tableRows = []
                }
            } else {
                readerScope = scope
                readerSelection = nil
                expandForReading(scope)
            }
        case .reference(let id, let scope):
            guard reader != nil else { return }
            readerScope = scope
            readerSelection = id
        }
    }

    func setExpanded(_ expanded: Bool, scope: ReferenceScope) {
        if reader == nil, let id = scope.collectionID {
            if expanded { expandedCollections.insert(id) } else { expandedCollections.remove(id) }
        } else {
            if expanded { expandedReaderScopes.insert(scope) } else { expandedReaderScopes.remove(scope) }
        }
    }

    func isExpanded(_ scope: ReferenceScope) -> Bool {
        if reader == nil, let id = scope.collectionID { return expandedCollections.contains(id) }
        return expandedReaderScopes.contains(scope)
    }

    func expandForReading(_ scope: ReferenceScope) {
        expandedReaderScopes.insert(scope)
        var ancestor = scope.collectionID
        while let id = ancestor, let collection = collections.first(where: { $0.id == id }) {
            expandedReaderScopes.insert(.collection(id))
            ancestor = collection.parentID
        }
    }

    func focusReferenceSearch() {
        if reader != nil { showsNavigator = true }
        referenceSearchRequest += 1
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

    func openPDF(for reference: BibliographicReference, in scope: ReferenceScope, inPreview: Bool = false) {
        guard let store else { return }
        let request = UUID()
        readerRequest = request
        Task {
            do {
                let pdf = try await findPDF(for: reference, in: store)
                guard request == readerRequest else { return }
                guard let pdf else {
                    showsInspector = true
                    if inPreview { report(WindowError.noAvailablePDF) }
                    return
                }
                if inPreview {
                    try await openInPreview(pdf.url)
                } else {
                    if reader == nil { readerSearch = "" }
                    readerScope = scope
                    readerSelection = reference.id
                    expandForReading(scope)
                    reader = pdf
                }
            } catch {
                guard request == readerRequest else { return }
                showsInspector = true
                report(error)
            }
        }
    }

    func closePDF() {
        readerRequest = UUID()
        reader = nil
        readerSelection = nil
        readerSearch = ""
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
    case duplicateField(String), incompleteField, noAvailablePDF, cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable: "The library is unavailable."
        case .libraryBusy: "Wait for the current library operation to finish."
        case .duplicateField(let name): "The field '\(name)' appears more than once."
        case .incompleteField: "Enter a name and a BibLaTeX expression for each field."
        case .noAvailablePDF: "The reference has no available PDF."
        case .cannotOpen(let name): "macOS could not open '\(name)'."
        }
    }
}
