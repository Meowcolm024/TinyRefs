import CoreTransferable
import Foundation
import SwiftUI
import TinyRefs
import UniformTypeIdentifiers

struct ReferenceRow: Identifiable {
    let reference: BibliographicReference
    let title: String
    let author: String
    let year: String
    let key: String
    var id: UUID { reference.id }

    init(_ reference: BibliographicReference) {
        self.reference = reference
        let metadata = reference.metadata
        key = metadata.citationKey
        let title = displayValue(metadata.fields["title"])
        self.title = title.isEmpty ? key : title
        author = displayValue(metadata.fields["author"])
        year = displayValue(metadata.fields["year"] ?? metadata.fields["date"])
    }
}

private func displayValue(_ expression: String?) -> String {
    guard var value = expression?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
    if value.first == "\"", value.last == "\"", value.count >= 2 {
        value = String(value.dropFirst().dropLast())
    }
    return value.replacingOccurrences(of: #"(?<!\\)[{}]"#, with: "", options: .regularExpression)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

struct ReferenceDrag: Codable, Sendable, Transferable {
    let id: UUID
    static let contentType = UTType(exportedAs: "org.tinyrefs.reference")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType).visibility(.ownProcess)
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
                        .draggable(ReferenceDrag(id: row.id))
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
                Button("New Reference…") { model.editor = .reference(nil) }
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
            Section("Collections") {
                ForEach(model.collectionTree) { node in
                    ScopeBranch(model: model, scope: .collection(node.id), icon: "folder", children: node.children)
                }
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
    @State private var receivingReferences = false

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

    private func label(leadingPadding: CGFloat = 0) -> some View {
        Label(model.title(for: scope), systemImage: icon)
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
            .modifier(FileDropHighlight(enabled: scope.allowsImport && !model.working) {
                model.dropBibliographies($0, in: scope)
            })
            .dropDestination(for: ReferenceDrag.self) { items, _ in
                guard let id = scope.collectionID, !model.working, !items.isEmpty else { return false }
                model.run { store in
                    for item in items {
                        try await store.setMembership(.init(collectionID: id, referenceID: item.id), isMember: true)
                    }
                }
                return true
            } isTargeted: { receivingReferences = $0 && scope.collectionID != nil && !model.working }
            .background(receivingReferences ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
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
            Button("Edit Reference…") { model.editor = .reference(reference) }.disabled(model.working)
            Button("Add Attachment…") { model.filePicker = .attach(reference.id) }.disabled(model.working)
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
}
