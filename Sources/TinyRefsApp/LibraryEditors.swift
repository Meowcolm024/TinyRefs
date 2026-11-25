import AppKit
import SwiftUI
import TinyRefs

struct LibraryEditorSheet: View {
    let model: LibraryWindowModel
    let editor: LibraryEditor

    var body: some View {
        switch editor {
        case .newReference:
            ReferenceEditorSheet(model: model)
        case .editReference(let reference):
            ReferenceEditorSheet(model: model, reference: reference)
        case .newCollection(let parent):
            CollectionEditorSheet(model: model, mode: .create, parentID: parent)
        case .renameCollection(let collection):
            CollectionEditorSheet(model: model, mode: .rename(collection), name: collection.name)
        case .moveCollection(let collection):
            CollectionEditorSheet(model: model, mode: .move(collection), parentID: collection.parentID)
        case .reassign(let attachment):
            ReassignEditorSheet(model: model, attachment: attachment)
        }
    }
}

private struct BibTeXEditor: NSViewRepresentable {
    @Binding var source: String
    let isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel("BibTeX")
        scrollView.drawsBackground = false
        Task { @MainActor [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.source = $source
        textView.isEditable = isEditable
        if textView.string != source { textView.string = source }
    }

    func makeCoordinator() -> Coordinator { Coordinator(source: $source) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: Binding<String>

        init(source: Binding<String>) { self.source = source }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            source.wrappedValue = textView.string
        }
    }
}

private struct EntryTypeComboBox: NSViewRepresentable {
    private static let commonTypes = [
        "article", "book", "booklet", "inbook", "incollection", "inproceedings", "manual",
        "mastersthesis", "misc", "online", "phdthesis", "proceedings", "report", "techreport",
        "thesis", "unpublished",
    ]

    @Binding var value: String

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.setAccessibilityLabel("Entry Type")
        comboBox.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        comboBox.isEditable = true
        comboBox.addItems(withObjectValues: Self.commonTypes)
        comboBox.numberOfVisibleItems = 10
        comboBox.hasVerticalScroller = true
        comboBox.delegate = context.coordinator
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.value = $value
        comboBox.isEnabled = context.environment.isEnabled
        if comboBox.stringValue != value { comboBox.stringValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var value: Binding<String>

        init(value: Binding<String>) { self.value = value }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            value.wrappedValue = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  let selected = comboBox.objectValueOfSelectedItem as? String else { return }
            value.wrappedValue = selected
        }
    }
}

private struct ReferenceEditorSheet: View {
    private enum InputMethod: Hashable {
        case bibTeX, fields
    }

    private struct Field: Identifiable {
        let id = UUID()
        var name: String
        var expression = ""

        var listKind: BibLaTeX.ListField? {
            BibLaTeX.ListField(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private enum Cell: Hashable {
        case name(UUID), value(UUID)

        var fieldID: UUID {
            switch self {
            case .name(let id), .value(let id): id
            }
        }
    }

    let model: LibraryWindowModel
    let reference: BibliographicReference?
    @Environment(\.dismiss) private var dismiss
    @State private var inputMethod: InputMethod = .bibTeX
    @State private var source = ""
    @State private var key: String
    @State private var entryType: String
    @State private var fields: [Field]
    @State private var selectedFieldID: UUID?
    @State private var valueDraft: FieldValueDraft?
    @State private var error: String?
    @FocusState private var focusedCell: Cell?

    init(model: LibraryWindowModel, reference: BibliographicReference? = nil) {
        self.model = model
        self.reference = reference
        _key = State(initialValue: reference?.metadata.citationKey ?? "")
        _entryType = State(initialValue: reference?.metadata.entryType ?? "misc")
        if let stored = reference?.metadata.fields {
            _fields = State(initialValue: stored.sorted { $0.key < $1.key }.map {
                Field(name: $0.key, expression: $0.value)
            })
        } else {
            _fields = State(initialValue: [Field(name: "title"), Field(name: "author"), Field(name: "year")])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(reference == nil ? "New Reference" : "Edit Reference").font(.headline)
                if reference == nil {
                    Spacer()
                    Picker("Input Method", selection: $inputMethod) {
                        Text("BibTeX").tag(InputMethod.bibTeX)
                        Text("Fields").tag(InputMethod.fields)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.working)
                }
            }
            if usesBibTeX {
                BibTeXEditor(source: $source, isEditable: !model.working)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
                            .allowsHitTesting(false)
                    }
            } else {
                HStack(spacing: 16) {
                    identityField("Citation Key") {
                        TextField("Citation Key", text: $key).labelsHidden().textFieldStyle(.roundedBorder)
                    }
                    identityField("Entry Type") {
                        EntryTypeComboBox(value: $entryType)
                    }
                    .frame(width: 180)
                }
                fieldTable
                fieldActions
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            EditorButtons(action: reference == nil ? "Create" : "Save", working: model.working,
                          enabled: canSubmit, submit: submit)
        }
        .padding(18)
        .frame(width: 680, height: 480)
        .onChange(of: inputMethod) { error = nil }
        .onChange(of: focusedCell) { _, cell in
            if let cell { selectedFieldID = cell.fieldID }
        }
        .sheet(item: $valueDraft) { draft in
            FieldValueEditorSheet(draft: draft) { expression in
                guard let index = fields.firstIndex(where: { $0.id == draft.id }) else { return }
                fields[index].expression = expression
            }
        }
    }

    private var usesBibTeX: Bool { reference == nil && inputMethod == .bibTeX }

    private var canSubmit: Bool {
        !(usesBibTeX ? source : key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        Task {
            do {
                if usesBibTeX {
                    try await model.createReference(fromBibTeX: source)
                } else if let reference {
                    try await model.save(metadata(), replacing: reference)
                } else {
                    try await model.createReference(metadata())
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func identityField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .font(.system(.body, design: .monospaced))
        .disabled(model.working)
    }

    private var fieldTable: some View {
        Table(fields, selection: $selectedFieldID) {
            TableColumn("Field") { field in
                TextField("Field Name", text: binding(\.name, for: field))
                    .textFieldStyle(.plain)
                    .focused($focusedCell, equals: .name(field.id))
            }
            .width(min: 110, ideal: 145, max: 215)
            TableColumn("BibTeX Value") { field in
                if let kind = field.listKind {
                    Button { editValue(field) } label: {
                        Label(field.expression.isEmpty ? kind.title : preview(field.expression), systemImage: "list.bullet")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Edit \(kind.title)")
                } else if field.expression.contains(where: \.isNewline) {
                    Button(preview(field.expression)) { editValue(field) }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .help("Edit BibTeX Value")
                } else {
                    TextField("Expression", text: binding(\.expression, for: field))
                        .textFieldStyle(.plain)
                        .focused($focusedCell, equals: .value(field.id))
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
        .tableStyle(.bordered)
        .alternatingRowBackgrounds(.enabled)
        .disabled(model.working)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let field = fields.first(where: { ids.contains($0.id) }) {
                if let kind = field.listKind {
                    Button("Edit \(kind.title)…") { editValue(field) }
                }
                Button("Edit as BibTeX…") { editValue(field, asList: false) }
                Button("Remove Field", role: .destructive) { removeField(id: field.id) }
            } else {
                Button("Add Field", action: addField)
            }
        }
    }

    private var fieldActions: some View {
        let selected = fields.first { $0.id == selectedFieldID }
        return HStack {
            ControlGroup {
                Button("Add Field", systemImage: "plus", action: addField).help("Add Field")
                Button("Remove Field", systemImage: "minus") {
                    if let selected { removeField(id: selected.id) }
                }
                .help("Remove Field")
                .disabled(selected == nil)
            }
            .labelStyle(.iconOnly)

            Spacer()
            Button(selected?.listKind.map { "Edit \($0.title)…" } ?? "Edit Value…") {
                if let selected { editValue(selected) }
            }
            .disabled(selected == nil)
        }
        .disabled(model.working)
    }

    private func binding(_ keyPath: WritableKeyPath<Field, String>, for field: Field) -> Binding<String> {
        Binding(get: {
            fields.first(where: { $0.id == field.id })?[keyPath: keyPath] ?? field[keyPath: keyPath]
        }, set: { value in
            guard let index = fields.firstIndex(where: { $0.id == field.id }) else { return }
            fields[index][keyPath: keyPath] = value
        })
    }

    private func addField() {
        let field = Field(name: "")
        let index = fields.firstIndex { $0.id == selectedFieldID }.map { $0 + 1 } ?? 0
        fields.insert(field, at: index)
        selectedFieldID = field.id
        focusedCell = .name(field.id)
    }

    private func removeField(id: UUID) {
        guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
        if focusedCell?.fieldID == id { focusedCell = nil }
        fields.remove(at: index)
        if selectedFieldID == id {
            selectedFieldID = fields.isEmpty ? nil : fields[min(index, fields.count - 1)].id
        }
    }

    private func editValue(_ field: Field, asList: Bool = true) {
        selectedFieldID = field.id
        let kind = asList ? field.listKind : nil
        do {
            let items: [String]
            if let kind, !field.expression.isEmpty {
                items = try BibLaTeX.listItems(in: field.expression, field: kind)
            } else {
                items = []
            }
            error = nil
            valueDraft = FieldValueDraft(id: field.id, expression: field.expression, kind: kind, items: items)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func metadata() throws -> ReferenceMetadata {
        var values: [String: String] = [:]
        var names: Set<String> = []
        for field in fields where !field.expression.isEmpty {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw WindowError.incompleteField }
            guard names.insert(name.lowercased()).inserted else { throw WindowError.duplicateField(name) }
            values[name] = field.expression
        }
        return .init(citationKey: key, entryType: entryType, fields: values)
    }
}

private extension BibLaTeX.ListField {
    var title: String { self == .author ? "Authors" : "Keywords" }
    var itemTitle: String { self == .author ? "Author" : "Keyword" }
    var hint: String {
        switch self {
        case .author: "Use BibTeX names such as Gödel, Kurt. Put a name containing ‘and’ in braces."
        case .keywords: "Enter one keyword per row. Put keywords containing commas in braces."
        }
    }
}

private struct FieldValueDraft: Identifiable {
    let id: UUID
    let expression: String
    let kind: BibLaTeX.ListField?
    let items: [String]
}

private struct FieldValueEditorSheet: View {
    private struct Item: Identifiable {
        let id = UUID()
        var text: String
    }

    let draft: FieldValueDraft
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expression: String
    @State private var items: [Item]
    @State private var selection: UUID?
    @State private var error: String?
    @FocusState private var focusedItem: UUID?

    init(draft: FieldValueDraft, apply: @escaping (String) -> Void) {
        self.draft = draft
        self.apply = apply
        _expression = State(initialValue: draft.expression)
        _items = State(initialValue: draft.items.map(Item.init(text:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.kind?.title ?? "BibTeX Value").font(.headline)
            if let kind = draft.kind {
                list(for: kind)
            } else {
                BibTeXEditor(source: $expression, isEditable: true)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
                            .allowsHitTesting(false)
                    }
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            EditorButtons(action: "Apply", working: false, enabled: items.allSatisfy { item in
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) { save() }
        }
        .padding(18)
        .frame(width: 500, height: 340)
        .onChange(of: focusedItem) { _, id in
            if let id { selection = id }
        }
    }

    private func list(for kind: BibLaTeX.ListField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach($items) { $item in
                    TextField(kind.itemTitle, text: $item.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...4)
                        .focused($focusedItem, equals: item.id)
                        .tag(item.id)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            .autocorrectionDisabled()

            HStack {
                ControlGroup {
                    Button("Add \(kind.itemTitle)", systemImage: "plus") {
                        let item = Item(text: "")
                        let index = items.firstIndex { $0.id == selection }.map { $0 + 1 } ?? items.count
                        items.insert(item, at: index)
                        selection = item.id
                        focusedItem = item.id
                    }
                    .help("Add \(kind.itemTitle)")
                    Button("Remove \(kind.itemTitle)", systemImage: "minus") {
                        items.removeAll { $0.id == selection }
                        selection = nil
                    }
                    .help("Remove \(kind.itemTitle)")
                    .disabled(selection == nil)
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
            Text(kind.hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        do {
            let edited = items.map(\.text)
            if let kind = draft.kind, edited != draft.items {
                expression = try BibLaTeX.listExpression(from: edited, field: kind)
            }
            apply(expression)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CollectionEditorSheet: View {
    enum Mode {
        case create, rename(LibraryCollection), move(LibraryCollection)
    }
    let model: LibraryWindowModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var parentID: UUID?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(model: LibraryWindowModel, mode: Mode, name: String = "", parentID: UUID? = nil) {
        self.model = model
        self.mode = mode
        _name = State(initialValue: name)
        _parentID = State(initialValue: parentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                switch mode {
                case .create:
                    nameField
                    parents
                case .rename:
                    nameField
                case .move(let collection):
                    Text(collection.name)
                    parents
                }
            }
            .disabled(model.working)
            if let error { Text(error).foregroundStyle(.red) }
            EditorButtons(action: action, working: model.working, enabled: canSave, submit: save)
        }
        .padding(20)
        .frame(width: 360)
        .defaultFocus($nameFocused, editsName)
    }

    private var nameField: some View {
        LabeledContent("Name") {
            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
        }
    }

    private var editsName: Bool {
        if case .move = mode { return false }
        return true
    }

    private func save() {
        guard canSave, !model.working else { return }
        let name = name
        let parentID = parentID
        Task {
            do {
                switch mode {
                case .create:
                    _ = try await model.perform { try await $0.createCollection(named: name, parentID: parentID) }
                    if let parentID { model.setExpanded(true, collectionID: parentID) }
                case .rename(let collection):
                    try await model.perform { try await $0.renameCollection(id: collection.id, to: name) }
                case .move(let collection):
                    try await model.moveCollection(id: collection.id, to: parentID)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private var title: String {
        switch mode {
        case .create: "New Collection"
        case .rename: "Rename Collection"
        case .move: "Move Collection"
        }
    }

    private var action: String {
        switch mode {
        case .create: "Create"
        case .rename: "Rename"
        case .move: "Move"
        }
    }

    private var canSave: Bool {
        return !editsName || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parents: some View {
        Picker("Parent", selection: $parentID) {
            Text("Top Level").tag(nil as UUID?)
            ForEach(model.collections.filter(canUseParent)) { collection in
                Text(collection.name).tag(Optional(collection.id))
            }
        }
    }

    private func canUseParent(_ parent: LibraryCollection) -> Bool {
        guard case .move(let collection) = mode else { return true }
        return model.canParentCollection(collection.id, under: parent.id)
    }
}

private struct ReassignEditorSheet: View {
    let model: LibraryWindowModel
    let attachment: AttachmentRecord
    @Environment(\.dismiss) private var dismiss
    @State private var references: [ReferenceRow] = []
    @State private var selectedID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reassign Attachment").font(.headline)
            Text(attachment.originalFilename)
            Picker("Reference", selection: $selectedID) {
                Text("Choose a reference").tag(nil as UUID?)
                ForEach(references) { row in Text(row.title).tag(Optional(row.id)) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            EditorButtons(action: "Reassign", working: model.working, enabled: selectedID != nil) {
                guard let id = selectedID else { return }
                Task {
                    do {
                        _ = try await model.perform { try await $0.reassignAttachment(id: attachment.id, to: id) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .padding(20)
        .frame(width: 390)
        .task {
            do {
                guard let store = model.store else { return }
                let candidates = try await store.references(in: .library, matching: nil)
                    .filter { $0.id != attachment.referenceID }
                references = try await ReferenceRow.prepare(candidates)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct EditorButtons: View {
    let action: String
    let working: Bool
    let enabled: Bool
    let submit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button(action, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled || working)
        }
    }
}
