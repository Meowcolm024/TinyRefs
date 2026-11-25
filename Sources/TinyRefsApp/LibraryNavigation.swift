import CoreTransferable
import Foundation
import SwiftUI
import TinyRefs
import UniformTypeIdentifiers

struct ReferenceRow: Identifiable {
    let reference: BibliographicReference
    let structured: StructuredBibliographyFields
    let title: String
    let author: String
    let year: String
    let key: String
    var id: UUID { reference.id }

    init(_ reference: BibliographicReference, _ structured: StructuredBibliographyFields) {
        self.reference = reference
        self.structured = structured
        key = reference.metadata.citationKey
        title = structured.title ?? key
        author = structured.authors.map(\.displayName).joined(separator: "; ")
        let date = structured.date
        year = (date?.start ?? date?.end).map { String($0.year) } ?? date?.text ?? ""
    }

    static func prepare(_ references: [BibliographicReference]) async throws -> [Self] {
        try await Task.detached(priority: .userInitiated) {
            let fields = try BibLaTeX.structuredFields(for: references.map(\.metadata))
            return zip(references, fields).map(Self.init)
        }.value
    }
}

struct ReferenceDrag: Codable, Sendable, Transferable {
    let referenceID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json).visibility(.ownProcess)
    }
}

enum CollectionDrop: Transferable {
    case reference(ReferenceDrag)
    case bibliography(URL)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: CollectionDrop.reference).visibility(.ownProcess)
        ProxyRepresentation(importing: CollectionDrop.bibliography)
    }
}

struct ReferenceTable: View {
    @Bindable var model: LibraryWindowModel

    var body: some View {
        let rows = model.tableRows.sorted(using: model.tableSort)
        Table(of: ReferenceRow.self, selection: $model.tableSelection, sortOrder: $model.tableSort) {
            TableColumn("Title", value: \.title) { row in
                Text(row.title).lineLimit(1).help(row.title)
                    .task(id: model.revision) { await model.refreshPDFAvailability(for: row.id) }
            }
            .width(min: 135, ideal: 290)
            TableColumn("Author", value: \.author) { row in
                Text(row.author).lineLimit(1).foregroundStyle(.secondary).help(row.author)
            }
            .width(min: 85, ideal: 160)
            TableColumn("Year", value: \.year) { row in
                Text(row.year).lineLimit(1).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 62)
            TableColumn("Citation Key", value: \.key) { row in
                Text(row.key).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 116)
        } rows: {
            ForEach(rows) { row in
                if row.reference.trashedAt == nil {
                    TableRow(row)
                        .draggable(ReferenceDrag(referenceID: row.id))
                        .dropDestination(for: URL.self) { urls in
                            _ = model.dropFiles(urls, on: row.reference)
                        }
                } else {
                    TableRow(row)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                ReferenceMenu(model: model, reference: row.reference, scope: model.tableScope)
            } else {
                Button("New Reference…") { model.editor = .newReference }
                Button("Import…") { model.filePicker = .importBibliography(model.tableScope) }
                    .disabled(!model.tableScope.allowsImport)
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                model.tableSelection = row.id
                model.openPDFInPreview(for: row.reference, showInspectorIfNoPDF: true)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    model.tableSearch.isEmpty ? "No References" : "No Matching References",
                    systemImage: model.tableSearch.isEmpty ? "books.vertical" : "magnifyingglass"
                )
                .allowsHitTesting(false)
            }
        }
        .modifier(FileDropHighlight(enabled: model.tableScope.allowsImport && !model.working) {
            model.dropBibliographies($0, in: model.tableScope)
        })
    }
}

struct LibrarySidebar: View {
    let model: LibraryWindowModel

    var body: some View {
        List(selection: Binding<ReferenceScope?>(
            get: { model.tableScope },
            set: { if let scope = $0 { model.selectScope(scope) } }
        )) {
            Section {
                ScopeBranch(model: model, scope: .library, icon: "books.vertical")
                ScopeBranch(model: model, scope: .unfiled, icon: "tray")
            }
            Section {
                ForEach(model.collectionTree) { node in
                    ScopeBranch(model: model, scope: .collection(node.id), icon: "folder", children: node.children)
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer(minLength: 0)
                    Button("New Collection", systemImage: "plus") { model.editor = .newCollection(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("New Collection")
                        .disabled(model.working)
                }
                .padding(.trailing, 12)
            }
            Section {
                ScopeBranch(model: model, scope: .trash, icon: "trash")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Library Navigator")
    }
}

private struct ScopeBranch: View {
    let model: LibraryWindowModel
    let scope: ReferenceScope
    let icon: String
    var children: [LibraryWindowModel.CollectionNode] = []
    @State private var receivingDrop = false

    var body: some View {
        if let id = scope.collectionID, !children.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedCollections.contains(id) },
                set: { model.setExpanded($0, collectionID: id) }
            )) {
                ForEach(children) { child in
                    ScopeBranch(model: model, scope: .collection(child.id), icon: "folder", children: child.children)
                }
            } label: {
                label(leadingPadding: 6)
            }
            .tag(scope)
        } else {
            label().tag(scope)
        }
    }

    @ViewBuilder private func label(leadingPadding: CGFloat = 0) -> some View {
        let row = Label(model.title(for: scope), systemImage: icon)
            .padding(.leading, leadingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                if let id = scope.collectionID, let collection = model.collections.first(where: { $0.id == id }) {
                    Button("New Subcollection…") { model.editor = .newCollection(id) }
                    Button("Rename Collection…") { model.editor = .renameCollection(collection) }
                    Button("Move Collection…") { model.editor = .moveCollection(collection) }
                    Divider()
                    Button("Delete Collection…", role: .destructive) { model.confirmation = .deleteCollection(collection) }
                } else if scope == .library {
                    Button("New Collection…") { model.editor = .newCollection(nil) }
                }
            }

        if let collectionID = scope.collectionID {
            row.dropDestination(for: CollectionDrop.self) { items, _ in
                model.dropOnCollection(items, id: collectionID)
            } isTargeted: { receivingDrop = $0 }
            .background(receivingDrop && !model.working ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        } else {
            row.modifier(FileDropHighlight(enabled: scope.allowsImport && !model.working) {
                model.dropBibliographies($0, in: scope)
            })
        }
    }
}

struct FileDropHighlight: ViewModifier {
    let enabled: Bool
    let accept: ([URL]) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in enabled && accept(urls) }
            isTargeted: { targeted = $0 }
            .overlay {
                if enabled, targeted {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct ReferenceMenu: View {
    let model: LibraryWindowModel
    let reference: BibliographicReference
    let scope: ReferenceScope

    var body: some View {
        Button("Copy Citation Key") { model.copyCitationKey(reference) }
        Button("Open PDF in Preview") { model.openPDFInPreview(for: reference) }
            .disabled(!model.previewableReferences.contains(reference.id))
        Divider()
        if reference.trashedAt == nil {
            Button("Edit Reference…") { model.editor = .editReference(reference) }.disabled(model.working)
            Button("Add Attachment…") { model.filePicker = .attach(reference.id) }.disabled(model.working)
            AddToCollectionMenu(model: model, referenceID: reference.id, existingIDs: existingCollectionIDs)
                .labelStyle(.titleOnly)
            if let collectionID = scope.collectionID {
                Button("Remove from Collection") { model.setMembership(reference.id, in: collectionID, isMember: false) }
                    .disabled(model.working)
            }
            Button("Move to Trash", role: .destructive) { model.trash(reference) }.disabled(model.working)
        } else {
            Button("Restore") { model.restore(reference) }.disabled(model.working)
            Button("Move to macOS Trash…", role: .destructive) { model.confirmation = .purge(reference) }
                .disabled(model.working)
        }
    }

    private var existingCollectionIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let details = model.details, details.reference.id == reference.id {
            ids = details.collectionIDs
        }
        if let collectionID = scope.collectionID { ids.insert(collectionID) }
        return ids
    }
}

struct AddToCollectionMenu: View {
    let model: LibraryWindowModel
    let referenceID: UUID
    let existingIDs: Set<UUID>

    var body: some View {
        let destinations = model.collections.filter { !existingIDs.contains($0.id) }
        Menu {
            ForEach(destinations) { collection in
                Button(collection.name) { model.setMembership(referenceID, in: collection.id, isMember: true) }
            }
        } label: {
            Label("Add to Collection", systemImage: "plus")
        }
        .disabled(model.working || destinations.isEmpty)
    }
}
