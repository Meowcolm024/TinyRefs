import AppKit
import Foundation
import OSLog
import TinyRefs
import UniformTypeIdentifiers

enum LibraryEditor: Identifiable {
    case reference(BibliographicReference?)
    case newCollection(UUID?)
    case renameCollection(LibraryCollection)
    case moveCollection(LibraryCollection)
    case reassign(AttachmentRecord)

    var id: String {
        switch self {
        case .reference(let reference): "reference-\(reference?.id.uuidString ?? "new")"
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

    var title: String {
        switch self {
        case .deleteCollection: "Delete Collection?"
        case .detach: "Remove Attachment?"
        case .purge: "Move to macOS Trash?"
        }
    }
    var action: String {
        switch self {
        case .deleteCollection: "Delete Collection"
        case .detach: "Remove Attachment"
        case .purge: "Move to macOS Trash"
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
    func save(_ metadata: ReferenceMetadata, replacing original: BibliographicReference?) async throws {
        if let original {
            let old = original.metadata
            let changes = ReferenceChanges(
                citationKey: old.citationKey == metadata.citationKey ? nil : metadata.citationKey,
                entryType: old.entryType == metadata.entryType ? nil : metadata.entryType,
                fields: metadata.fields.filter { old.fields[$0.key] != $0.value },
                removedFields: old.fields.keys.filter { metadata.fields[$0] == nil }
            )
            _ = try await perform { try await $0.updateReference(id: original.id, changes: changes) }
        } else {
            let reference = try await perform { try await $0.createReference(metadata) }
            tableScope = .unfiled
            tableSelection = reference.id
            tableSearch = ""
            showsInspector = true
        }
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
        run { [self] store in
            switch confirmation {
            case .deleteCollection(let collection):
                try await store.deleteCollection(id: collection.id)
            case .detach(let attachment):
                try await store.detachAttachment(id: attachment.id)
            case .purge(let reference):
                let result = try await store.purgeReference(id: reference.id)
                clearSelection(for: reference.id)
                if !result.missingAttachments.isEmpty {
                    notice = WindowNotice(
                        title: "Recovery Folder Sent to Trash",
                        message: "Missing attachments\n" + result.missingAttachments.map(\.originalFilename).joined(separator: "\n")
                    )
                }
            }
        }
    }

    func setMembership(_ referenceID: UUID, in collectionID: UUID, isMember: Bool) {
        run { store in
            try await store.setMembership(
                CollectionMembership(collectionID: collectionID, referenceID: referenceID), isMember: isMember
            )
        }
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
