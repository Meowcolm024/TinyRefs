import SwiftUI
import TinyRefs

struct ReferenceInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        if let reference = model.selectedReference {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    header(for: reference)
                    Divider()
                    metadata(for: reference)
                    if let details = model.details, details.reference.id == reference.id {
                        Divider()
                        collections(for: details)
                        Divider()
                        attachments(for: details)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Reference Inspector")
            .modifier(FileDropHighlight(enabled: reference.trashedAt == nil && !model.working) {
                model.dropFiles($0, on: reference)
            })
        } else {
            ContentUnavailableView("No Reference Selected", systemImage: "doc.text")
                .accessibilityLabel("Reference Inspector")
        }
    }

    private func header(for reference: BibliographicReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ReferenceRow(reference).title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(reference.metadata.entryType)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if reference.trashedAt == nil {
                    Button("Edit Reference…") { model.editor = .reference(reference) }
                        .disabled(model.working)
                } else {
                    Button("Restore") { model.restore(reference) }
                        .disabled(model.working)
                }
                Menu {
                    ReferenceMenu(model: model, reference: reference, scope: model.currentScope)
                } label: {
                    Label("Reference Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func metadata(for reference: BibliographicReference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            information("Citation Key", reference.metadata.citationKey, monospaced: true)
            ForEach(reference.metadata.fields.keys.sorted(), id: \.self) { name in
                information(name, reference.metadata.fields[name] ?? "")
            }
        }
    }

    private func information(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func collections(for details: LibraryWindowModel.Details) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Collections").font(.headline)
                Spacer()
                if details.reference.trashedAt == nil {
                    Menu {
                        ForEach(model.collections.filter { !details.collectionIDs.contains($0.id) }) { collection in
                            Button(collection.name) { model.setMembership(details.reference.id, in: collection.id, isMember: true) }
                        }
                    } label: {
                        Label("Add to Collection", systemImage: "plus").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.working || model.collections.allSatisfy { details.collectionIDs.contains($0.id) })
                }
            }
            if details.collectionIDs.isEmpty {
                Text("Unfiled").foregroundStyle(.secondary)
            }
            ForEach(model.collections.filter { details.collectionIDs.contains($0.id) }) { collection in
                HStack {
                    Label(collection.name, systemImage: "folder")
                    Spacer()
                    if details.reference.trashedAt == nil {
                        Button("Remove from \(collection.name)", systemImage: "minus.circle") {
                            model.setMembership(details.reference.id, in: collection.id, isMember: false)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove from Collection")
                        .disabled(model.working)
                    }
                }
            }
        }
    }

    private func attachments(for details: LibraryWindowModel.Details) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.headline)
                Spacer()
                if details.reference.trashedAt == nil {
                    Button("Add Attachment", systemImage: "plus") {
                        model.filePicker = .attach(details.reference.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add Attachment")
                    .disabled(model.working)
                }
            }
            if details.attachments.isEmpty {
                Text("No attachments").foregroundStyle(.secondary)
            }
            ForEach(details.attachments) { attachment in
                HStack {
                    Button {
                        model.openAttachment(attachment)
                    } label: {
                        Label(attachment.originalFilename, systemImage: "doc")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help("Open in Default App")
                    Spacer()
                    Menu {
                        Button("Open in Default App") { model.openAttachment(attachment) }
                        if details.reference.trashedAt == nil {
                            Button("Reassign Attachment…") { model.editor = .reassign(attachment) }.disabled(model.working)
                            Button("Remove Attachment…", role: .destructive) { model.confirmation = .detach(attachment) }
                                .disabled(model.working)
                        }
                    } label: {
                        Label("Attachment Actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}
