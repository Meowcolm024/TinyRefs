import AppKit
import ArgumentParser
import Foundation
import TinyRefs

extension TinyRefsCommand {
    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a file into the library and print its attachment UUID.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument
        @Argument(help: "The file to attach.", completion: .file())
        var file: String

        func run() async throws {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let attachment = try await databaseOptions.openLibrary().attachFile(at: url, to: reference.uuid)
            print(displayID(attachment.id))
        }
    }

    struct Detach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an attachment and its managed copy.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var attachment: AttachmentArgument

        func run() async throws {
            try await databaseOptions.openLibrary().detachAttachment(id: attachment.id)
        }
    }

    struct Reassign: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move an attachment to another active reference.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var attachment: AttachmentArgument
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            try await databaseOptions.openLibrary().reassignAttachment(id: attachment.id, to: reference.uuid)
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open an attachment in its default macOS application.")

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument
        @Option(help: ArgumentHelp("Open this attachment.", valueName: "attachment-uuid"), transform: parseAttachmentID)
        var attachment: UUID?

        func run() async throws {
            let file = try await databaseOptions.openLibrary().attachmentFile(for: reference.uuid, attachmentID: attachment)
            let opened = await MainActor.run { NSWorkspace.shared.open(file) }
            guard opened else { throw AttachmentOpenError(filename: file.lastPathComponent) }
        }
    }

    struct Purge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a trashed reference and its attachments to macOS Trash as a recovery folder."
        )

        @OptionGroup var databaseOptions: DatabaseOptions
        @OptionGroup var reference: ReferenceArgument

        func run() async throws {
            let result = try await databaseOptions.openLibrary().purgeReference(id: reference.uuid)
            for attachment in result.missingAttachments {
                let message = "Warning: Managed attachment '\(attachment.originalFilename)' (\(displayID(attachment.id))) was missing.\n"
                try FileHandle.standardError.write(contentsOf: Data(message.utf8))
            }
            if let url = result.recoveryURL { print(url.path) }
        }
    }
}

struct AttachmentArgument: ParsableArguments {
    @Argument(help: ArgumentHelp("The attachment UUID.", valueName: "attachment-uuid"), transform: parseAttachmentID)
    var id: UUID
}

private func parseAttachmentID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw ValidationError("Expected an attachment UUID.") }
    return id
}

private struct AttachmentOpenError: LocalizedError {
    let filename: String
    var errorDescription: String? { "macOS could not open attachment '\(filename)'." }
}
