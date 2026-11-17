import AppKit

/// Batch extraction's optional shared folder (#326): "Collect them in a new folder" in the batch
/// destination panel. Each archive still lands in its own place (Extract All's rules) inside it,
/// so archives never mix; the folder only gathers one batch's results.
///
/// The folder is always new: a name already taken, by a folder or a file, gets the next number,
/// so nothing that was there before ends up among the results. If nothing is extracted into it
/// (every archive failed or was cancelled), it is removed again — only while it is empty.
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

    /// rmdir(2): removes the folder only when nothing is in it. True when it was removed.
    @discardableResult
    static func removeIfEmpty(_ folder: URL) -> Bool {
        rmdir(folder.path) == 0
    }
}

extension ResultFolder {
    /// The folder a batch extracts into: the chosen one, or a new one made in it. Explains and
    /// returns nil when the new folder can't be made.
    @MainActor
    static func destination(for choice: ExtractDestination.BatchChoice) async -> URL? {
        guard choice.collects else { return choice.folder }
        do {
            return try create(in: choice.folder)
        } catch {
            _ = await Prompts.explain(Failure(
                String(localized: "Couldn’t make a folder for the results."),
                advice: error.localizedDescription, code: ErrorCode(.extract, .unknown)))
            return nil
        }
    }
}
