import Foundation
import GRDB

public struct SQLiteLibrary: ReferenceStore, CollectionStore {
    public static var defaultDirectoryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("TinyRefs", isDirectory: true)
    }

    let database: DatabaseQueue
    static let containsText = DatabaseFunction("tinyrefs_contains_text", argumentCount: 2, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]),
              let term = String.fromDatabaseValue(values[1]) else { return false }
        return text.lowercased().contains(term)
    }

    /// Opens or creates the database and attachment directory for a library.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            db.add(function: Self.containsText)
        }

        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrate(database)
        self.database = database
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createLibrary") { db in
            try db.create(table: ReferenceRow.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("citation_key", .text).notNull().collate(.binary).unique()
                table.column("entry_type", .text).notNull()
                table.column("trashed_at", .integer)
            }
            try db.create(table: ReferenceFieldRow.databaseTableName) { table in
                table.column("reference_id", .text).notNull()
                    .references(ReferenceRow.databaseTableName, onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("value", .text).notNull()
                table.primaryKey(["reference_id", "name"])
            }
            try db.create(table: AttachmentRow.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("reference_id", .text).notNull().indexed()
                    .references(ReferenceRow.databaseTableName, onDelete: .cascade)
                table.column("relative_path", .text).notNull().unique()
                table.column("original_filename", .text).notNull()
            }
            try db.create(table: CollectionRow.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull().collate(.binary).unique()
                    .check { length($0) > 0 }
                table.column("parent_id", .text).indexed()
                    .references(CollectionRow.databaseTableName, column: "id", onDelete: .setNull)
                    .check { $0 != Column("id") }
            }
            try db.create(table: MembershipRow.databaseTableName) { table in
                table.column("collection_id", .text).notNull()
                    .references(CollectionRow.databaseTableName, onDelete: .cascade)
                table.column("reference_id", .text).notNull().indexed()
                    .references(ReferenceRow.databaseTableName, onDelete: .cascade)
                table.primaryKey(["collection_id", "reference_id"])
            }
        }
        try migrator.migrate(database)
    }

    static func requireReference(_ id: UUID, in db: Database) throws -> ReferenceRow {
        guard let record = try ReferenceRow.fetchOne(db, key: id.databaseKey) else {
            throw LibraryError.referenceNotFound(id)
        }
        return record
    }
}

extension UUID {
    var databaseKey: String { uuidString.lowercased() }
}
