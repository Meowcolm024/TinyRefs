import SwiftUI
import TinyRefs

struct ReferenceInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        let row = model.selectedRow
        let reference = row?.reference
        VStack(spacing: 0) {
            if let row {
                header(row.title)
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        actions(for: row.reference)
                        Divider()
                        metadata(for: row)
                        if let details = model.details, details.reference.id == row.id {
                            Divider()
                            collections(for: details)
                            Divider()
                            attachments(for: details)
                        }
                    }
                    .padding([.horizontal, .bottom], 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Reference Inspector")
            } else if model.tableSelection.count > 1 {
                ContentUnavailableView("\(model.tableSelection.count) References Selected", systemImage: "doc.on.doc")
                    .accessibilityLabel("Reference Inspector")
            } else {
                ContentUnavailableView("No Reference Selected", systemImage: "doc.text")
                    .accessibilityLabel("Reference Inspector")
            }
        }
        .modifier(FileDropHighlight(enabled: reference.map { $0.trashedAt == nil && !model.working } ?? false) { urls in
            guard let reference else { return false }
            return model.dropFiles(urls, on: reference)
        })
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    private func actions(for reference: BibliographicReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reference.metadata.entryType)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if reference.trashedAt == nil {
                    Button("Edit Reference…") { model.editor = .editReference(reference) }
                        .disabled(model.working)
                } else {
                    Button("Restore") { model.restore(reference) }
                        .disabled(model.working)
                }
                Menu {
                    ReferenceMenu(model: model, reference: reference, scope: model.tableScope)
                } label: {
                    Label("Reference Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func metadata(for row: ReferenceRow) -> some View {
        let parsed = row.structured
        let fields = row.reference.metadata.fields
        let readable = [
            ("Editors", parsed.editors.map(\.displayName).joined(separator: "; "), ["editor"]),
            ("Publication Date", parsed.date?.text ?? "", ["date", "year", "month", "day"]),
            ("Event Date", parsed.eventDate?.text ?? "", ["eventdate"]),
            ("Original Date", parsed.originalDate?.text ?? "", ["origdate"]),
            ("Access Date", parsed.accessDate?.text ?? "", ["urldate"]),
            ("Published In", parsed.containerTitle ?? "", ["journaltitle", "journal", "booktitle"]),
            ("Publisher", parsed.publisher ?? "", ["publisher"]),
            ("Keywords", parsed.keywords.joined(separator: ", "), ["keywords"]),
            ("Abstract", parsed.abstract ?? "", ["abstract"]),
        ].filter { !$0.1.isEmpty }
        var represented = Set(readable.flatMap(\.2))
        if parsed.title != nil { represented.insert("title") }
        if !parsed.authors.isEmpty { represented.insert("author") }
        if parsed.doi != nil { represented.insert("doi") }
        if parsed.url != nil { represented.insert("url") }

        return VStack(alignment: .leading, spacing: 10) {
            information("Citation Key", row.key, monospaced: true)
            if !parsed.authors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Authors").font(.caption).foregroundStyle(.secondary)
                    ForEach(parsed.authors.indices, id: \.self) { index in
                        Text(parsed.authors[index].displayName)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if let doi = parsed.doi {
                webLink("DOI", doi, destination: doiDestination(doi))
            }
            if let url = parsed.url {
                webLink("URL", url, destination: doiDestination(url) ?? webDestination(url))
            }
            ForEach(readable, id: \.0) { label, value, _ in
                information(label, value)
            }
            ForEach(fields.keys.filter { !represented.contains($0) }.sorted(), id: \.self) { name in
                information(name, fields[name] ?? "")
            }
        }
    }

    private func webLink(_ label: String, _ value: String, destination: URL?) -> some View {
        Group {
            if let destination {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Link(destination: destination) {
                        Text(value)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        model.confirmation = .openLink(url)
                        return .handled
                    })
                }
            } else {
                information(label, value)
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
                    AddToCollectionMenu(
                        model: model, referenceID: details.reference.id, existingIDs: details.collectionIDs
                    )
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
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
                let openTitle = attachment.isPDF ? "Open in Preview" : "Open in Default App"
                HStack {
                    Button {
                        model.openAttachment(attachment)
                    } label: {
                        Label(attachment.originalFilename, systemImage: "doc")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help(openTitle)
                    Spacer()
                    Menu {
                        Button(openTitle) { model.openAttachment(attachment) }
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

private func webDestination(_ value: String) -> URL? {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = components.host, !host.isEmpty else { return nil }
    return components.url
}

private func doiDestination(_ value: String) -> URL? {
    let identifier = value.prefix(4).lowercased() == "doi:"
        ? value.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        : value
    var resolver = URLComponents()
    resolver.scheme = "https"
    resolver.host = "doi.org"

    if let url = webDestination(identifier),
       let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let host = source.host?.lowercased(), ["doi.org", "dx.doi.org", "www.doi.org"].contains(host) {
        resolver.percentEncodedPath = source.percentEncodedPath
        resolver.percentEncodedQuery = source.percentEncodedQuery
        resolver.percentEncodedFragment = source.percentEncodedFragment
        return resolver.url
    }

    let parts = identifier.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].hasPrefix("10."), parts[0].count > 3, !parts[1].isEmpty else { return nil }
    resolver.path = "/\(identifier)"
    return resolver.url
}
