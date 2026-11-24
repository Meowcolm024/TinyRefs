import AppKit
import Foundation
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
            closePDF()
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
                if reader?.attachmentID == attachment.id { closePDF() }
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
                guard NSWorkspace.shared.open(url) else { throw WindowError.cannotOpen(attachment.originalFilename) }
            } catch { report(error) }
        }
    }

    func copyCitationKey(_ reference: BibliographicReference) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.metadata.citationKey, forType: .string)
    }

    private func clearSelection(for id: UUID) {
        if reader?.reference.id == id { closePDF() }
        if tableSelection == id { tableSelection = nil }
        if readerSelection == id { readerSelection = nil }
    }
}
