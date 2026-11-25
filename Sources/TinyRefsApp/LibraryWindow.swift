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

    var body: some View {
        let query = model.tableQuery
        let details = model.detailsRequest
        NavigationSplitView(columnVisibility: visibility) {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 215, max: 360)
        } detail: {
            ReferenceTable(model: model)
                .navigationTitle(model.title(for: model.tableScope))
        }
        .inspector(isPresented: $model.showsInspector) {
            ReferenceInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        let title = model.showsInspector ? "Hide Inspector" : "Show Inspector"
                        Button(title, systemImage: "sidebar.right") { model.showsInspector.toggle() }
                            .labelStyle(.iconOnly)
                            .help(title)
                    }
                }
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.libraryWindow, model)
        .task(id: model.revision) { await model.loadCollections() }
        .task(id: query) { await model.loadTable(query) }
        .task(id: details) { await model.loadDetails(details) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.revision += 1
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
            Button(confirmation.action, role: confirmation.isDestructive ? .destructive : nil) {
                model.confirm(confirmation)
            }
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
            Button("New Reference", systemImage: "plus") { model.editor = .newReference }
                .help("New Reference")
                .disabled(model.working)
            Button("Import Bibliography", systemImage: "square.and.arrow.down") {
                model.filePicker = .importBibliography(model.tableScope)
            }
            .help("Import Bibliography")
            .disabled(!model.tableScope.allowsImport || model.working)
        }

        ToolbarItem {
            ReferenceToolbarSearch(text: $model.tableSearch, focusRequest: model.referenceSearchRequest)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

private struct ReferenceToolbarSearch: View {
    @Binding var text: String
    let focusRequest: Int
    @State private var showsSearch = false
    @State private var reservesSearchWidth = false
    @State private var inputFocusRequest = 0
    @State private var searchHasFocus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let buttonSize: CGFloat = 32
        let expandedWidth: CGFloat = 185

        return HStack(spacing: 0) {
            if showsSearch {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: buttonSize)
                    .accessibilityHidden(true)
            } else {
                Button(action: showSearch) {
                    Image(systemName: "magnifyingglass")
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search References")
                .help("Search References")
            }

            searchField
                .frame(width: expandedWidth - buttonSize)
                .opacity(showsSearch ? 1 : 0)
                .disabled(!showsSearch)
                .accessibilityHidden(!showsSearch)
        }
        .frame(width: showsSearch ? expandedWidth : buttonSize, height: buttonSize, alignment: .leading)
        .clipped()
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                .opacity(showsSearch && searchHasFocus ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: reservesSearchWidth ? expandedWidth : buttonSize, height: buttonSize, alignment: .trailing)
        .onChange(of: focusRequest) { _, _ in showSearch() }
    }

    private var searchField: some View {
        HStack(spacing: 0) {
            ToolbarSearchField(
                text: $text, isEnabled: showsSearch, focusRequest: inputFocusRequest,
                onFocusChange: { focused in
                    searchHasFocus = focused
                    if !focused, text.isEmpty { hideSearch() }
                },
                onEscape: {
                    text = ""
                    hideSearch()
                }
            )
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    text = ""
                    inputFocusRequest += 1
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            }
        }
        .padding(.trailing, 10)
    }

    private var searchAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    private func showSearch() {
        // Give the capsule space to grow before the toolbar clips it to the item's width.
        reservesSearchWidth = true
        withAnimation(searchAnimation) { showsSearch = true }
        inputFocusRequest += 1
    }

    private func hideSearch() {
        guard showsSearch else { return }
        withAnimation(searchAnimation) {
            showsSearch = false
            searchHasFocus = false
        } completion: {
            if !showsSearch { reservesSearchWidth = false }
        }
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let focusRequest: Int
    let onFocusChange: (Bool) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search References"
        field.setAccessibilityLabel("Search References")
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        let needsFocus = focusRequest != coordinator.field.focusRequest
        coordinator.field = self
        field.isEnabled = isEnabled
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        if needsFocus, isEnabled {
            Task { @MainActor [weak field, weak coordinator] in
                guard let field, field.isEnabled, let coordinator, coordinator.field.focusRequest == focusRequest,
                      field.window?.makeFirstResponder(field) == true else { return }
                coordinator.field.onFocusChange(true)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: ToolbarSearchField

        init(field: ToolbarSearchField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            if let input = notification.object as? NSTextField { field.text = input.stringValue }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            field.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let input = notification.object as? NSTextField else { return }
            Task { @MainActor [weak self, weak input] in
                guard let input, input.isEnabled, input.currentEditor() == nil else { return }
                self?.field.onFocusChange(false)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            field.onEscape()
            control.window?.makeFirstResponder(nil)
            return true
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
            Button("New Reference…") { model?.editor = .newReference }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil || model?.working == true)
            Button("New Collection…") { model?.editor = .newCollection(model?.tableScope.collectionID) }
                .disabled(model == nil || model?.working == true)
        }
        CommandGroup(after: .importExport) {
            Button("Import…") {
                if let model { model.filePicker = .importBibliography(model.tableScope) }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model?.tableScope.allowsImport != true || model?.working == true)
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
            Button("Search References") { model?.referenceSearchRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
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
