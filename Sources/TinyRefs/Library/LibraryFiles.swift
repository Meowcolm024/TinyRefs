import Darwin
import Foundation

struct LibraryFiles: Sendable {
    let directory: URL

    var attachments: URL { directory.appendingPathComponent("attachments", isDirectory: true) }
    var staging: URL { directory.appendingPathComponent(".staging", isDirectory: true) }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(".library.lock")
        let flags = O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC | O_NOFOLLOW
        var descriptor: Int32

        repeat {
            descriptor = Darwin.open(lockURL.path, flags, mode_t(0o600))
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        // Closing the descriptor releases the lock. Keep the lock file in place.
        defer { Darwin.close(descriptor) }
        return try body()
    }

    func prepare() throws {
        try prepareDirectory(attachments)
        try prepareDirectory(staging)
    }

    func recover(retaining attachmentIDs: Set<UUID>) throws {
        try removeUnreferencedDirectories(in: staging, retaining: [])
        try removeUnreferencedDirectories(in: attachments, retaining: attachmentIDs)
    }

    func stage() throws -> URL {
        let url = staging.appendingPathComponent(UUID().databaseKey, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func attachmentDirectory(for id: UUID) -> URL {
        attachments.appendingPathComponent(id.databaseKey, isDirectory: true)
    }

    func availableFile(for attachment: AttachmentRecord) throws -> URL? {
        let components = attachment.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "attachments",
              components[1] == attachment.id.databaseKey, Self.isBasename(String(components[2])) else {
            throw LibraryError.invalidManagedPath(attachment.relativePath)
        }

        let folder = attachmentDirectory(for: attachment.id)
        guard let folderType = try fileType(at: folder) else { return nil }
        guard folderType == .typeDirectory else { throw LibraryError.invalidManagedPath(folder.path) }
        let file = folder.appendingPathComponent(String(components[2]))
        guard let type = try fileType(at: file) else { return nil }
        guard type == .typeRegular else { throw LibraryError.invalidManagedPath(file.path) }
        return file
    }

    func removeAfterCommit(_ urls: [URL]) throws {
        for url in urls {
            do {
                if let type = try fileType(at: url) {
                    guard type == .typeDirectory else { throw LibraryError.invalidManagedPath(url.path) }
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                throw LibraryError.fileCleanupFailed(url.path, error.localizedDescription)
            }
        }
    }

    func fileType(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                throw LibraryError.invalidManagedPath(url.path)
            }
            return type
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return nil
        }
    }

    static func isBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private func removeUnreferencedDirectories(in parent: URL, retaining ids: Set<UUID>) throws {
        for item in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: item.lastPathComponent),
                  id.databaseKey == item.lastPathComponent,
                  !ids.contains(id),
                  try fileType(at: item) == .typeDirectory else { continue }
            try FileManager.default.removeItem(at: item)
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        if let type = try fileType(at: url) {
            guard type == .typeDirectory else { throw LibraryError.invalidManagedPath(url.path) }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }
}
