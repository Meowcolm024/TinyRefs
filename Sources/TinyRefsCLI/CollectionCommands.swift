import ArgumentParser
import Foundation
import TinyRefs

struct CollectionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collection",
        abstract: "Manage collections and reference memberships.",
        subcommands: [List.self, Create.self, Rename.self, Move.self, Delete.self, Add.self, Remove.self]
    )

    @OptionGroup var databaseOptions: DatabaseOptions

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List collections and their parent IDs as JSON.")

        @OptionGroup var databaseOptions: DatabaseOptions

        func run() async throws {
            let collections = try await databaseOptions.openLibrary().collections()
            try printJSON(collections.map(CollectionSummary.init))
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a collection.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @Argument(help: "The new collection name.")
        var name: String
        @Option(help: "The exact name of the parent collection.")
        var parent: String?

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let parentID = try await resolveParent(named: parent, in: library)
            try await library.createCollection(named: name, parentID: parentID)
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a collection.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @Argument(help: "The current collection name.")
        var name: String
        @Argument(help: "The replacement collection name.")
        var newName: String

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let collection = try await requireCollection(named: name, in: library)
            try await library.renameCollection(id: collection.id, to: newName)
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a collection and its descendants.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @Argument(help: "The collection to move.")
        var name: String
        @Option(help: "The new parent name. Omit to move to the top level.")
        var parent: String?

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let collection = try await requireCollection(named: name, in: library)
            let parentID = try await resolveParent(named: parent, in: library)
            try await library.moveCollection(id: collection.id, to: parentID)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a collection and move its children to the top level."
        )

        @OptionGroup var databaseOptions: DatabaseOptions
        @Argument(help: "The collection to delete.")
        var name: String

        func run() async throws {
            let library = try databaseOptions.openLibrary()
            let collection = try await requireCollection(named: name, in: library)
            try await library.deleteCollection(id: collection.id)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an active reference to a collection.")

        @OptionGroup var membership: MembershipArguments

        func run() async throws {
            try await membership.set(isMember: true)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a reference from a collection.")

        @OptionGroup var membership: MembershipArguments

        func run() async throws {
            try await membership.set(isMember: false)
        }
    }
}

private func resolveParent(named name: String?, in store: any CollectionStore) async throws -> UUID? {
    guard let name else { return nil }
    return try await requireCollection(named: name, in: store).id
}

struct MembershipArguments: ParsableArguments {
    @OptionGroup var databaseOptions: DatabaseOptions
    @Argument(help: "The exact collection name.")
    var name: String
    @OptionGroup var reference: ReferenceArgument

    func set(isMember: Bool) async throws {
        let library = try databaseOptions.openLibrary()
        let collection = try await requireCollection(named: name, in: library)
        let membership = CollectionMembership(collectionID: collection.id, referenceID: reference.uuid)
        try await library.setMembership(membership, isMember: isMember)
    }
}

private struct CollectionSummary: Encodable {
    let id: String
    let name: String
    let parentID: String?

    init(_ collection: LibraryCollection) {
        id = displayID(collection.id)
        name = collection.name
        parentID = collection.parentID.map(displayID)
    }
}
