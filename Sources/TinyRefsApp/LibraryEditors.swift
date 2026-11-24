import SwiftUI
import TinyRefs

struct LibraryEditorSheet: View {
    let model: LibraryWindowModel
    let editor: LibraryEditor

    var body: some View {
        switch editor {
        case .reference(let reference):
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

private struct ReferenceEditorSheet: View {
    private struct Field: Identifiable {
        let id = UUID()
        var name: String
        var expression: String
    }

    let model: LibraryWindowModel
    let reference: BibliographicReference?
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var entryType: String
    @State private var fields: [Field]
    @State private var error: String?

    init(model: LibraryWindowModel, reference: BibliographicReference?) {
        self.model = model
        self.reference = reference
        _key = State(initialValue: reference?.metadata.citationKey ?? "")
        _entryType = State(initialValue: reference?.metadata.entryType ?? "article")
        let stored = reference?.metadata.fields ?? ["title": "", "author": "", "year": ""]
        _fields = State(initialValue: stored.keys.sorted().map { Field(name: $0, expression: stored[$0] ?? "") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reference == nil ? "New Reference" : "Edit Reference").font(.headline)
            Form {
                TextField("Citation Key", text: $key)
                TextField("Entry Type", text: $entryType)
                Section("BibLaTeX Fields") {
                    ForEach($fields) { $field in
                        HStack(alignment: .top) {
                            TextField("Field Name", text: $field.name).frame(width: 110)
                            TextField("Expression", text: $field.expression, axis: .vertical)
                                .lineLimit(1...4)
                            Button("Remove Field", systemImage: "minus.circle") {
                                fields.removeAll { $0.id == field.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Field", systemImage: "plus") { fields.append(Field(name: "", expression: "")) }
                    Text("Use BibLaTeX expressions such as {Linear Haskell}. Use {} for an empty field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            EditorButtons(action: reference == nil ? "Create" : "Save", working: model.working,
                          enabled: !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task {
                    do {
                        try await model.save(metadata(), replacing: reference)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .padding(18)
        .frame(width: 540, height: 470)
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
                try await model.perform { store in
                    switch mode {
                    case .create:
                        _ = try await store.createCollection(named: name, parentID: parentID)
                    case .rename(let collection):
                        try await store.renameCollection(id: collection.id, to: name)
                    case .move(let collection):
                        try await store.moveCollection(id: collection.id, to: parentID)
                    }
                }
                if let parentID { model.expandedCollections.insert(parentID) }
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
        var ancestor: LibraryCollection? = parent
        while let current = ancestor {
            if current.id == collection.id { return false }
            ancestor = model.collections.first { $0.id == current.parentID }
        }
        return true
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
