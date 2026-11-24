import Foundation
import GRDB

extension SQLiteLibrary {
    public func collections() async throws -> [LibraryCollection] {
        try await database.read { db in
            try CollectionRow.order(CollectionRow.CodingKeys.name).fetchAll(db).map(\.collection)
        }
    }

    public func memberships(for referenceID: UUID) async throws -> [CollectionMembership] {
        try await database.read { db in
            try MembershipRow.filter(MembershipRow.CodingKeys.referenceID == referenceID.databaseKey)
                .order(MembershipRow.CodingKeys.collectionID)
                .fetchAll(db)
                .map(\.membership)
        }
    }

    @discardableResult
    public func createCollection(named name: String, parentID: UUID? = nil) async throws -> LibraryCollection {
        try Self.validateCollectionName(name)
        let collection = CollectionRow(id: UUID(), name: name, parentID: parentID)
        do {
            try await database.write { db in
                if let parentID { _ = try Self.requireCollection(parentID, in: db) }
                try collection.insert(db)
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateCollectionName(name)
        }
        return collection.collection
    }

    public func renameCollection(id: UUID, to name: String) async throws {
        try Self.validateCollectionName(name)
        do {
            try await database.write { db in
                var collection = try Self.requireCollection(id, in: db)
                collection.name = name
                try collection.update(db, columns: [CollectionRow.CodingKeys.name])
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateCollectionName(name)
        }
    }

    public func deleteCollection(id: UUID) async throws {
        try await database.write { db in
            guard try CollectionRow.deleteOne(db, key: id.databaseKey) else {
                throw LibraryError.collectionNotFound(id)
            }
        }
    }

    public func moveCollection(id: UUID, to parentID: UUID?) async throws {
        try await database.write { db in
            var collection = try Self.requireCollection(id, in: db)
            var ancestorID = parentID
            var visited: Set<UUID> = [id]
            while let ancestor = ancestorID {
                guard visited.insert(ancestor).inserted else { throw LibraryError.collectionCycle(id) }
                ancestorID = try Self.requireCollection(ancestor, in: db).parentID
            }
            collection.parentID = parentID
            try collection.update(db, columns: [CollectionRow.CodingKeys.parentID])
        }
    }

    public func setMembership(_ membership: CollectionMembership, isMember: Bool) async throws {
        try await database.write { db in
            let reference = try Self.requireReference(membership.referenceID, in: db)
            guard reference.trashedAt == nil else { throw LibraryError.referenceInTrash(reference.id) }
            _ = try Self.requireCollection(membership.collectionID, in: db)

            if isMember {
                let record = MembershipRow(collectionID: membership.collectionID, referenceID: reference.id)
                try record.insert(db, onConflict: .ignore)
            } else {
                try MembershipRow
                    .filter(MembershipRow.CodingKeys.collectionID == membership.collectionID.databaseKey)
                    .filter(MembershipRow.CodingKeys.referenceID == reference.id.databaseKey)
                    .deleteAll(db)
            }
        }
    }

    private static func validateCollectionName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.blankCollectionName
        }
    }

    static func requireCollection(_ id: UUID, in db: Database) throws -> CollectionRow {
        guard let collection = try CollectionRow.fetchOne(db, key: id.databaseKey) else {
            throw LibraryError.collectionNotFound(id)
        }
        return collection
    }
}
