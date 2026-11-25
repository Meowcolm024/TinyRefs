import AppKit
import Foundation
import OSLog
import TinyRefs
import UniformTypeIdentifiers

enum LibraryEditor: Identifiable {
    case newReference
    case editReference(BibliographicReference)
    case newCollection(UUID?)
    case renameCollection(LibraryCollection)
    case moveCollection(LibraryCollection)
    case reassign(AttachmentRecord)

    var id: String {
        switch self {
        case .newReference: "reference-new"
        case .editReference(let reference): "reference-\(reference.id.uuidString)"
        case .newCollection: "new-collection"
        case .renameCollection(let collection): "rename-\(collection.id)"
        case .moveCollection(let collection): "move-\(collection.id)"
        case .reassign(let attachment): "reassign-\(attachment.id)"
        }
    }
}

enum LibraryConfirmation {
    case deleteCollection(LibraryCollection)
    case detach(AttachmentRecord)
    case purge(BibliographicReference)
    case openLink(URL)

    var isDestructive: Bool {
        if case .openLink = self { return false }
        return true
    }

    var title: String {
        switch self {
        case .deleteCollection: "Delete Collection?"
        case .detach: "Remove Attachment?"
        case .purge: "Move to macOS Trash?"
        case .openLink: "Open Link?"
        }
    }
    var action: String {
        switch self {
        case .deleteCollection: "Delete Collection"
        case .detach: "Remove Attachment"
        case .purge: "Move to macOS Trash"
        case .openLink: "Open Link"
        }
    }
    var detail: String {
        switch self {
        case .deleteCollection(let collection):
            "“\(collection.name)” and its memberships will be removed. Its child collections will move to the top level."
        case .detach(let attachment):
            "The managed copy of “\(attachment.originalFilename)” will be removed."
        case .purge(let reference):
            "A recovery folder for “\(reference.metadata.citationKey)” will be sent to macOS Trash."
        case .openLink(let url):
            url.absoluteString
        }
    }
}

enum LibraryFilePicker: Equatable {
    case importBibliography(ReferenceScope)
    case attach(UUID)

    var types: [UTType] {
        switch self {
        case .importBibliography: [UTType(filenameExtension: "bib") ?? .item]
        case .attach: [.item]
        }
    }
}

extension LibraryWindowModel {
    func createReference(fromBibTeX source: String) async throws {
        let reference = try await perform { store in
            let entries = try await Task.detached {
                try BibLaTeX.references(from: Data(source.utf8))
            }.value
            guard entries.count == 1, let metadata = entries.first else { throw WindowError.expectedSingleReference }
            return try await store.createReference(metadata)
        }
        tableScope = .unfiled
        tableSelection = reference.id
        tableSearch = ""
        showsInspector = true
    }

    func save(_ metadata: ReferenceMetadata, replacing original: BibliographicReference) async throws {
        let old = original.metadata
        let changes = ReferenceChanges(
            citationKey: old.citationKey == metadata.citationKey ? nil : metadata.citationKey,
            entryType: old.entryType == metadata.entryType ? nil : metadata.entryType,
            fields: metadata.fields.filter { old.fields[$0.key] != $0.value },
            removedFields: old.fields.keys.filter { metadata.fields[$0] == nil }
        )
        _ = try await perform { try await $0.updateReference(id: original.id, changes: changes) }
    }

    func trash(_ reference: BibliographicReference) {
        run { [self] store in
            try await store.moveReferenceToTrash(id: reference.id)
            clearSelection(for: reference.id)
        }
    }

    func restore(_ reference: BibliographicReference) {
        run { [self] store in
            try await store.restoreReference(id: reference.id)
            clearSelection(for: reference.id)
        }
    }

    func confirm(_ confirmation: LibraryConfirmation) {
        switch confirmation {
        case .deleteCollection(let collection):
            run { try await $0.deleteCollection(id: collection.id) }
        case .detach(let attachment):
            run { try await $0.detachAttachment(id: attachment.id) }
        case .purge(let reference):
            run { [self] store in
                let result = try await store.purgeReference(id: reference.id)
                clearSelection(for: reference.id)
                if !result.missingAttachments.isEmpty {
                    notice = WindowNotice(
                        title: "Recovery Folder Sent to Trash",
                        message: "Missing attachments\n" + result.missingAttachments.map(\.originalFilename).joined(separator: "\n")
                    )
                }
            }
        case .openLink(let url):
            if !NSWorkspace.shared.open(url) { report(WindowError.cannotOpen(url.absoluteString)) }
        }
    }

    func setMembership(_ referenceID: UUID, in collectionID: UUID, isMember: Bool) {
        run { store in
            try await store.setMembership(
                CollectionMembership(collectionID: collectionID, referenceID: referenceID), isMember: isMember
            )
        }
    }

    func dropOnCollection(_ items: [CollectionDrop], id collectionID: UUID) -> Bool {
        guard !working, !items.isEmpty else { return false }
        let referenceIDs = items.compactMap { item -> UUID? in
            if case .reference(let drag) = item { return drag.referenceID }
            return nil
        }
        if referenceIDs.count == items.count {
            run { store in
                for referenceID in referenceIDs {
                    try await store.setMembership(.init(collectionID: collectionID, referenceID: referenceID), isMember: true)
                }
            }
            return true
        }

        let urls = items.compactMap { item -> URL? in
            if case .bibliography(let url) = item { return url }
            return nil
        }
        return urls.count == items.count && dropBibliographies(urls, in: .collection(collectionID))
    }

    func handleFiles(_ urls: [URL], for picker: LibraryFilePicker) {
        run { store in
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                switch picker {
                case .importBibliography(let scope):
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    try await store.importBibLaTeX(data, into: scope.collectionID)
                case .attach(let id):
                    try await store.attachFile(at: url, to: id)
                }
            }
        }
    }

    func dropBibliographies(_ urls: [URL], in scope: ReferenceScope) -> Bool {
        guard !working, scope.allowsImport, !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "bib" }) else { return false }
        handleFiles(urls, for: .importBibliography(scope))
        return true
    }

    func dropFiles(_ urls: [URL], on reference: BibliographicReference) -> Bool {
        guard !working, reference.trashedAt == nil, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        handleFiles(urls, for: .attach(reference.id))
        return true
    }

    func openAttachment(_ attachment: AttachmentRecord) {
        guard let store else { return }
        Task {
            do {
                let url = try await store.attachmentFile(for: attachment.referenceID, attachmentID: attachment.id)
                if attachment.isPDF {
                    try await openInPreview(url)
                } else if !NSWorkspace.shared.open(url) {
                    throw WindowError.cannotOpen(attachment.originalFilename)
                }
            } catch { report(error) }
        }
    }

    func openPDFInPreview(for reference: BibliographicReference, showInspectorIfNoPDF: Bool = false) {
        guard let store else { return }
        Task {
            do {
                if let url = try await firstAvailablePDF(for: reference.id, in: store) {
                    try await openInPreview(url)
                } else if showInspectorIfNoPDF {
                    showsInspector = true
                } else {
                    throw WindowError.noAvailablePDF
                }
            } catch {
                showsInspector = true
                report(error)
            }
        }
    }

    func refreshPDFAvailability(for id: UUID) async {
        guard let store else { return }
        let requestedRevision = revision
        let available: Bool
        do {
            available = try await firstAvailablePDF(for: id, in: store) != nil
        } catch LibraryError.missingAttachmentFile {
            available = false
        } catch {
            guard !Task.isCancelled, requestedRevision == revision else { return }
            Logger(subsystem: "org.tinyrefs.app", category: "Attachments")
                .debug("Could not check PDF availability: \(error.localizedDescription)")
            available = false
        }
        guard !Task.isCancelled, requestedRevision == revision else { return }
        if available { previewableReferences.insert(id) } else { previewableReferences.remove(id) }
    }

    func copyCitationKey(_ reference: BibliographicReference) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.metadata.citationKey, forType: .string)
    }

    private func clearSelection(for id: UUID) {
        if tableSelection == id { tableSelection = nil }
    }
}

extension AttachmentRecord {
    var isPDF: Bool { URL(fileURLWithPath: originalFilename).pathExtension.lowercased() == "pdf" }
}

@MainActor
private func firstAvailablePDF(for referenceID: UUID, in store: any LibraryStore) async throws -> URL? {
    let attachments = try await store.attachments(for: referenceID).filter(\.isPDF)
    var firstMissingFilename: String?
    for attachment in attachments {
        do {
            return try await store.attachmentFile(for: referenceID, attachmentID: attachment.id)
        } catch LibraryError.missingAttachmentFile(let filename) {
            firstMissingFilename = firstMissingFilename ?? filename
        }
    }
    if let firstMissingFilename { throw LibraryError.missingAttachmentFile(firstMissingFilename) }
    return nil
}

@MainActor
private func openInPreview(_ url: URL) async throws {
    guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
        throw WindowError.cannotOpen(url.lastPathComponent)
    }
    _ = try await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: .init())
}
