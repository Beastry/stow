import Darwin
import Foundation

/// Each engine process owns one staging directory across all its XPC connections.
/// The kernel releases the ownership lock even if the process crashes or is killed.
final class EngineStaging: Sendable {
    let directory: URL
    private let descriptor: Int32

    init(temporary: URL = FileManager.default.temporaryDirectory) throws {
        let manager = FileManager.default
        let root = temporary.appending(path: "StowEngineStaging", directoryHint: .isDirectory)
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let rootLock = try Self.openDirectory(root)
        defer { close(rootLock) }

        // Hold the root lock across directory creation and ownership acquisition so another
        // startup cannot mistake an incompletely initialized directory for an abandoned one.
        try Self.lock(rootLock)
        let previous = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for candidate in previous where UUID(uuidString: candidate.lastPathComponent) != nil {
            guard let owner = try? Self.openDirectory(candidate) else { continue }
            if flock(owner, LOCK_EX | LOCK_NB) == 0 { try? manager.removeItem(at: candidate) }
            close(owner)
        }

        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            let descriptor = try Self.openDirectory(directory)
            do {
                try Self.lock(descriptor)
            } catch {
                close(descriptor)
                throw error
            }
            self.directory = directory
            self.descriptor = descriptor
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private static func lock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit { close(descriptor) }
}
