import Foundation
import GRDB

public struct SQLiteLibrary: ReferenceStore, CollectionStore, AttachmentStore {
    public static var defaultDirectoryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("TinyRefs", isDirectory: true)
    }

    public let databaseURL: URL
    let database: DatabaseQueue
    let files: LibraryFiles
    private static let databaseFilename = "library.sqlite"
    private static let initialMigration = "createLibrary"
    static let containsText = DatabaseFunction("tinyrefs_contains_text", argumentCount: 2, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]),
              let term = String.fromDatabaseValue(values[1]) else { return false }
        return text.lowercased().contains(term)
    }

    /// Opens or creates the database and attachment directory for a library.
    public init(directory: URL) throws {
        try self.init(directory: directory, requireExisting: false)
    }

    /// Opens an existing TinyRefs library from its directory or database file.
    public init(existingAt location: URL) throws {
        var isDirectory: ObjCBool = false
        guard location.isFileURL, FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory),
              isDirectory.boolValue || location.lastPathComponent == Self.databaseFilename else {
            throw LibraryError.invalidLibraryLocation(location)
        }
        let directory = isDirectory.boolValue ? location : location.deletingLastPathComponent()
        try self.init(directory: directory.resolvingSymlinksInPath().standardizedFileURL, requireExisting: true)
    }

    /// Creates a library in a new directory. The final path must be unused.
    public static func create(at directory: URL) throws -> Self {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw LibraryError.libraryLocationExists(directory)
        }
        return try Self(directory: directory)
    }

    private init(directory: URL, requireExisting: Bool) throws {
        let databaseURL = directory.appendingPathComponent(Self.databaseFilename)
        let files = LibraryFiles(directory: directory)
        if requireExisting {
            guard try files.fileType(at: databaseURL) == .typeRegular else {
                throw LibraryError.invalidLibraryLocation(directory)
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            db.add(function: Self.containsText)
        }

        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrate(database, checkingLibraryAt: requireExisting ? directory : nil)
        try database.writeWithoutTransaction { db in
            try files.withLock {
                try files.prepare()
                let ids = try AttachmentRow.select(AttachmentRow.CodingKeys.id, as: UUID.self).fetchSet(db)
                try files.recover(retaining: ids)
            }
        }
        self.databaseURL = databaseURL
        self.database = database
        self.files = files
    }

    // Acquire the file lock before starting a SQLite transaction so all writers use the same order.
    func withFileLock<T: Sendable>(_ operation: @Sendable (Database) throws -> T) async throws -> T {
        try await database.writeWithoutTransaction { db in
            try files.withLock { try operation(db) }
        }
    }

    private static func migrate(_ database: DatabaseQueue, checkingLibraryAt directory: URL?) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(initialMigration) { db in
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
        if let directory {
            let isLibrary = try database.read { db in
                let tables = [ReferenceRow.databaseTableName, ReferenceFieldRow.databaseTableName,
                              AttachmentRow.databaseTableName, CollectionRow.databaseTableName,
                              MembershipRow.databaseTableName]
                return try migrator.appliedIdentifiers(db).contains(initialMigration) &&
                    tables.allSatisfy { try db.tableExists($0) }
            }
            guard isLibrary else { throw LibraryError.invalidLibraryLocation(directory) }
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
