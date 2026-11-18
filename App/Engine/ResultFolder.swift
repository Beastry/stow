import AppKit

/// Batch extraction's optional shared folder (#326): "Collect them in a new folder" in the batch
/// destination panel. Each archive still lands in its own place (Extract All's rules) inside it,
/// so archives never mix; the folder only gathers one batch's results.
///
/// The folder is always new: a name already taken, by a folder or a file, gets the next number,
/// so nothing that was there before ends up among the results. If nothing is extracted into it
/// (every archive failed or was cancelled), it is removed again — only while it is empty, and only
/// while it is still the folder the batch made (`Claim`).
enum ResultFolder {
    static var defaultName: String { String(localized: "Extracted Archives") }
    /// The panel's last choice. Panel memory, like the last destination, not a Settings preference.
    static let rememberKey = "batch.collectsInNewFolder"

    /// "Extracted Archives", or "Extracted Archives 2"… Created with mkdir(2), which fails on any
    /// existing name, so a folder that is already there is never adopted.
    static func create(in parent: URL, named name: String = defaultName, attempts: Int = 9_999) throws -> URL {
        for attempt in 1...max(attempts, 1) {
            let url = parent.appending(path: Extraction.numbered(name, attempt), directoryHint: .isDirectory)
            if mkdir(url.path, 0o755) == 0 { return url }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    /// A directory's file identity. A path names whatever is there now; this names one folder.
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        /// The directory at `url` itself (a symbolic link is not followed), or nil.
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// The folder one batch made, shared by that batch's jobs. It is known by identity, so a
    /// folder somebody else puts at the same path later is never treated as the batch's own.
    /// Ownership ends when the folder is removed or turns out to be gone or replaced.
    final class Claim {
        let parent: URL
        let name: String
        private(set) var folder: URL?
        private var identity: Identity?

        /// Makes a new folder in `parent` (see `create`).
        init(in parent: URL, named name: String = ResultFolder.defaultName) throws {
            self.parent = parent
            self.name = name
            try make()
        }

        /// The folder to extract into: the one made earlier while it is still that same folder,
        /// otherwise a new numbered one made now. A retry never adopts an occupied path.
        func current() throws -> URL {
            if let folder, let identity, Identity(folder) == identity { return folder }
            relinquish()
            try make()
            return folder!
        }

        /// rmdir(2) while it is still the batch's own folder: only an empty folder goes. True when
        /// it was removed. Ownership ends then, and also when the folder was replaced meanwhile.
        @discardableResult
        func removeIfEmpty() -> Bool {
            guard let folder, let identity else { return false }
            guard Identity(folder) == identity else {
                relinquish()
                return false
            }
            guard rmdir(folder.path) == 0 else { return false }
            relinquish()
            return true
        }

        private func make() throws {
            let made = try ResultFolder.create(in: parent, named: name)
            guard let identity = Identity(made) else { throw POSIXError(.ENOENT) }
            folder = made
            self.identity = identity
        }

        private func relinquish() {
            folder = nil
            identity = nil
        }
    }

    /// Where a batch goes: the chosen folder, or a new folder made in it with its claim.
    struct Destination {
        let folder: URL
        let claim: Claim?
    }
}

extension ResultFolder.Claim: Equatable {
    static func == (lhs: ResultFolder.Claim, rhs: ResultFolder.Claim) -> Bool { lhs === rhs }
}

extension ResultFolder {
    /// The folder a batch extracts into: the chosen one, or a new one made in it. Explains and
    /// returns nil when the new folder can't be made.
    @MainActor
    static func destination(for choice: ExtractDestination.BatchChoice) async -> Destination? {
        guard choice.collects else { return Destination(folder: choice.folder, claim: nil) }
        do {
            let claim = try Claim(in: choice.folder)
            return Destination(folder: try claim.current(), claim: claim)
        } catch {
            _ = await Prompts.explain(Failure(
                String(localized: "Couldn’t make a folder for the results."),
                advice: error.localizedDescription, code: ErrorCode(.extract, .unknown)))
            return nil
        }
    }
}
