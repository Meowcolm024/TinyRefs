import AppKit
import SwiftUI
import TinyRefs
import UniformTypeIdentifiers

struct LibraryWindow: View {
    let directory: URL
    @State private var model = LibraryWindowModel()

    var body: some View {
        Group {
            if model.store != nil {
                LibraryBrowser(model: model)
            } else if let error = model.startupError {
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.open(directory: directory) } }
                }
            } else {
                ProgressView("Opening Library…")
            }
        }
        .task { await model.open(directory: directory) }
    }
}

private struct LibraryBrowser: View {
    @Bindable var model: LibraryWindowModel
    @State private var pickingFiles = false
    @State private var pendingPicker: LibraryFilePicker?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let query = model.tableQuery
        let details = model.detailsRequest
        NavigationSplitView(columnVisibility: visibility) {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 215, max: 360)
        } detail: {
            if let reader = model.reader {
                PDFReaderPane(session: reader).id(reader.id)
                    .navigationTitle(reader.url.lastPathComponent)
            } else {
                ReferenceTable(model: model)
                    .navigationTitle(model.title(for: model.tableScope))
            }
        }
        .inspector(isPresented: $model.showsInspector) {
            ReferenceInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.libraryWindow, model)
        .task(id: model.revision) { await model.loadCollections() }
        .task(id: query) { await model.loadTable(query) }
        .task(id: details) { await model.loadDetails(details) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.revision += 1
        }
        .onChange(of: model.referenceSearchRequest) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in
            if focused, model.reader != nil { model.showsNavigator = true }
        }
        .onChange(of: model.filePicker) { _, choice in
            if let choice {
                pendingPicker = choice
                model.filePicker = nil
                pickingFiles = true
            }
        }
        .fileImporter(
            isPresented: $pickingFiles,
            allowedContentTypes: pendingPicker?.types ?? [.item],
            allowsMultipleSelection: true
        ) { result in
            do {
                let urls = try result.get()
                if let pendingPicker { model.handleFiles(urls, for: pendingPicker) }
            } catch { model.report(error) }
        }
        .sheet(item: $model.editor) { editor in
            LibraryEditorSheet(model: model, editor: editor)
        }
        .alert(model.notice?.title ?? "TinyRefs", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice?.message ?? "")
        }
        .alert(model.confirmation?.title ?? "Confirm", isPresented: Binding(
            get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }
        ), presenting: model.confirmation) { confirmation in
            Button(confirmation.action, role: .destructive) { model.confirm(confirmation) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.detail)
        }
    }

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.showsNavigator ? .all : .detailOnly },
            set: { model.showsNavigator = $0 != .detailOnly }
        )
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let reader = model.reader {
                Button("Close PDF", systemImage: "xmark") { model.closePDF() }
                    .help("Close PDF")
                Button("Find in PDF", systemImage: "doc.text.magnifyingglass") { reader.showFind() }
                    .help("Find in PDF")
            } else {
                Button("New Reference", systemImage: "plus") { model.editor = .reference(nil) }
                    .help("New Reference")
                    .disabled(model.working)
                Button("Import Bibliography", systemImage: "square.and.arrow.down") {
                    model.filePicker = .importBibliography(model.currentScope)
                }
                .help("Import Bibliography")
                .disabled(!model.currentScope.allowsImport || model.working)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search References", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search References")
                if !model.search.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { model.search = "" }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(width: 185, height: 23)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Button(model.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                model.showsInspector.toggle()
            }
            .help(model.showsInspector ? "Hide Inspector" : "Show Inspector")
        }
    }
}

extension LibraryWindowModel {
    func title(for scope: ReferenceScope) -> String {
        switch scope {
        case .library: "Library"
        case .unfiled: "Unfiled Items"
        case .trash: "Trash"
        case .collection(let id): collections.first(where: { $0.id == id })?.name ?? "Collection"
        }
    }
}

private struct LibraryWindowKey: FocusedValueKey {
    typealias Value = LibraryWindowModel
}

extension FocusedValues {
    var libraryWindow: LibraryWindowModel? {
        get { self[LibraryWindowKey.self] }
        set { self[LibraryWindowKey.self] = newValue }
    }
}

struct LibraryCommands: Commands {
    @FocusedValue(\.libraryWindow) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Reference…") { model?.editor = .reference(nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil || model?.working == true)
            Button("New Collection…") { model?.editor = .newCollection(model?.currentScope.collectionID) }
                .disabled(model == nil || model?.working == true)
        }
        CommandGroup(after: .importExport) {
            Button("Import…") {
                if let model { model.filePicker = .importBibliography(model.currentScope) }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model?.currentScope.allowsImport != true || model?.working == true)
        }
        CommandGroup(after: .sidebar) {
            Button(model?.showsNavigator == true ? "Hide Navigator" : "Show Navigator") {
                model?.showsNavigator.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model == nil)
            Button(model?.showsInspector == true ? "Hide Inspector" : "Show Inspector") {
                model?.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model == nil)
            Divider()
            Button("Search References") { model?.focusReferenceSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
            Button(model?.reader == nil ? "Find References" : "Find in PDF") {
                if let reader = model?.reader { reader.showFind() } else { model?.focusReferenceSearch() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model == nil)
            Button("Close PDF") { model?.closePDF() }
                .disabled(model?.reader == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Citation Key") {
                if let model, let reference = model.selectedReference { model.copyCitationKey(reference) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model?.selectedReference == nil)
        }
    }
}
