import Foundation

/// Translates publication errors without hiding retained output behind a cancellation result.
nonisolated enum PublicationRecovery {
    static func paths(in error: any Error, otherwise fallback: [URL]) -> [URL] {
        if case ExclusivePublication.Failure.rollbackIncomplete(let paths) = error { return paths }
        return fallback
    }

    static func retained(_ paths: [URL]) -> EngineError {
        let locations = Array(Set(paths.map(\.path))).sorted().joined(separator: "\n")
        return EngineError(.failed, String(localized: "Cleanup could not finish. Review these locations before trying again: \(locations)"))
    }

    static func engineError(_ error: any Error) -> EngineError {
        switch error {
        case is CancellationError:
            return EngineError(.cancelled)
        case ExclusivePublication.Failure.rollbackIncomplete(let paths):
            return retained(paths)
        case ExclusivePublication.Failure.system(_, let path, let code):
            let name = URL(filePath: path).lastPathComponent
            return EngineError(.failed, String(localized: "Couldn’t move “\(name)” into place: \(String(cString: strerror(code)))."))
        case ExclusivePublication.Failure.unsupportedSource(let path):
            return EngineError(.failed, String(localized: "“\(URL(filePath: path).lastPathComponent)” could not be copied safely. It may have changed, or this disk may not support its file type or metadata."))
        case ExclusivePublication.Failure.collision:
            return EngineError(.failed, String(localized: "A file with that name appeared at the destination. Try again to choose another name."))
        default:
            return EngineError(error)
        }
    }

    /// Restoring a Trash backup must still work after the initiating task has been cancelled.
    /// A copy fallback deliberately retains the backup in Trash as an additional recovery copy.
    static func restore(_ backup: URL, to original: URL) async throws {
        try await Task.detached {
            let options = ExclusivePublication.Options(checkCancellation: {})
            let receipt = try ExclusivePublication.publishSynchronously(source: backup, to: original,
                                                                        options: options, checkCancellation: {})
            receipt.commit()
        }.value
    }
}
