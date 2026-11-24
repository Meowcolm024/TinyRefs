import Foundation

public protocol ReferenceReader: Sendable {
    /// Looks up a reference by its stable ID, including references in Trash.
    func reference(id: UUID) async throws -> BibliographicReference?
    /// Searches citation keys and field values within the selected scope.
    func references(in scope: ReferenceScope, matching text: String?) async throws
        -> [BibliographicReference]
    func attachments(for referenceID: UUID) async throws -> [AttachmentRecord]
}

public protocol ReferenceStore: ReferenceReader {
    /// Imports one UTF-8 bibliography and assigns optional memberships in one transaction.
    @discardableResult
    func importBibLaTeX(_ data: Data, into collectionID: UUID?) async throws -> [BibliographicReference]
    @discardableResult
    func createReference(_ metadata: ReferenceMetadata) async throws -> BibliographicReference
    /// Replaces the metadata and all fields of an active reference in one transaction.
    @discardableResult
    func updateReference(id: UUID, metadata: ReferenceMetadata) async throws -> BibliographicReference
    /// Applies changes to the latest metadata in one transaction. Field assignments follow removals.
    @discardableResult
    func updateReference(id: UUID, changes: ReferenceChanges) async throws -> BibliographicReference
    func moveReferenceToTrash(id: UUID) async throws
    func restoreReference(id: UUID) async throws
    func purgeReference(id: UUID) async throws -> PurgedReference
}

public protocol AttachmentStore: Sendable {
    /// Copies a regular file into the library for an active reference.
    @discardableResult
    func attachFile(at source: URL, to referenceID: UUID) async throws -> AttachmentRecord
    /// Removes the record and managed copy from an active reference.
    func detachAttachment(id: UUID) async throws
    /// Transfers ownership between active references while preserving the attachment ID and path.
    @discardableResult
    func reassignAttachment(id: UUID, to referenceID: UUID) async throws -> AttachmentRecord
    /// Resolves a specific attachment or the first available file for a reference.
    func attachmentFile(for referenceID: UUID, attachmentID: UUID?) async throws -> URL
}

extension ReferenceReader {
    /// Exports active references from the whole library or a collection's direct membership.
    public func exportBibLaTeX(fromCollection collectionID: UUID? = nil) async throws -> String {
        let scope = collectionID.map(ReferenceScope.collection) ?? .library
        let entries = try await references(in: scope, matching: nil)
        return try BibLaTeX.serialize(entries.map(\.metadata))
    }
}

public protocol CollectionStore: Sendable {
    func collections() async throws -> [LibraryCollection]
    func memberships(for referenceID: UUID) async throws -> [CollectionMembership]
    @discardableResult
    func createCollection(named name: String, parentID: UUID?) async throws -> LibraryCollection
    func renameCollection(id: UUID, to name: String) async throws
    /// Moves a collection and its descendants. A nil parent moves it to the top level.
    func moveCollection(id: UUID, to parentID: UUID?) async throws
    /// Removes the collection's memberships and moves its children to the top level.
    func deleteCollection(id: UUID) async throws
    /// Sets the membership of an active reference. Repeating the same request is safe.
    func setMembership(_ membership: CollectionMembership, isMember: Bool) async throws
}
