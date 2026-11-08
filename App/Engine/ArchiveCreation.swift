import Foundation
import Synchronization

/// Creates and verifies archives in private staging before publishing them:
///
/// 1. Stow streams the files to the engine, already renamed and filtered for the audience.
/// 2. The engine compresses (and optionally tests) them inside its own container.
/// 3. It streams the archive back into a staging folder from `.itemReplacementDirectory` on the
///    destination's volume. Publication prefers an exclusive rename; unsupported volumes use
///    an exclusive, cancellable copy, whose partial output is visible while it is written.
enum ArchiveCreation {
    /// What to do when the archive's name is already taken.
    enum Conflict: Sendable {
        /// "Project 2.zip".
        case keepBoth
        /// The old archive (and any of its volumes) goes to the Trash.
        case replace
    }

    struct Result: Sendable {
        var placed: [URL]
        var report: CreateReport
    }

    /// `name` is the archive's name without extension. `totalBytes` is the file data in `items`, for
    /// progress.
    static func run(_ items: [TreeStream.Item], totalBytes: Int64, attributes: Bool, request: CreateRequest,
                    named name: String, in destination: URL, conflict: Conflict = .keepBoth,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws(EngineError) -> Result {
        if request.format == .dmg {
            return try await DiskImageCreation.run(items, request: request, named: name, in: destination,
                                                   conflict: conflict, onProgress: onProgress)
        }
        let engine = ArchiveEngine.shared
        let meter = Meter(total: totalBytes, onProgress: onProgress)
        let creation = try await engine.create(items, attributes: attributes, request: request,
                                               onSent: meter.sent, onProgress: meter.compressed)
        defer { engine.discard(operation: creation.operationID) }
        if Task.isCancelled { throw EngineError(.cancelled) }

        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: destination, create: true)
        } catch {
            throw EngineError(.failed, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        try await engine.receive(operation: creation.operationID, into: staging)
        if Task.isCancelled { throw EngineError(.cancelled) }

        // The engine names files after `archiveName`; keep only what follows it (".zip", ".7z.001").
        let produced = SevenZip.safeName(request.archiveName)
        let parts = creation.report.files.map { file in
            (staging.appending(path: file), String(file.dropFirst(produced.count)))
        }
        guard !parts.isEmpty, parts.allSatisfy({ FileManager.default.fileExists(atPath: $0.0.path) }) else {
            throw EngineError(.failed, String(localized: "The new archive didn’t arrive."))
        }
        let placed = try await place(parts, named: name, format: request.format, in: destination, conflict: conflict)
        onProgress(1)
        return Result(placed: placed, report: creation.report)
    }

    /// Names in `destination` that packing `name` would collide with: the archive, or any of its volumes.
    static func existing(named name: String, format: PackFormat, in destination: URL) -> [URL] {
        let base = name + "." + format.fileExtension
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        return contents.filter { $0 == base || isVolume($0, of: base) }.sorted().map { destination.appending(path: $0) }
    }

    /// "Project.zip.001", "Project.zip.002", …
    private static func isVolume(_ file: String, of base: String) -> Bool {
        guard file.hasPrefix(base + ".") else { return false }
        let suffix = file.dropFirst(base.count + 1)
        return suffix.count >= 3 && suffix.allSatisfy(\.isNumber)
    }

    /// Moves each part into place as `name` (+ its suffix), numbering all parts alike ("Project 2.zip")
    /// until none is taken. Publication never replaces an existing name; if one fails, earlier
    /// parts are rolled back conservatively and any retained output is reported.
    static func place(_ parts: [(URL, String)], named name: String, format: PackFormat, in destination: URL,
                      conflict: Conflict,
                      publicationOptions: ExclusivePublication.Options = .init()) async throws(EngineError) -> [URL] {
        var backups: [(original: URL, trash: URL)] = []
        do {
            if conflict == .replace {
                for old in existing(named: name, format: format, in: destination) {
                    var trashed: NSURL?
                    do {
                        try FileManager.default.trashItem(at: old, resultingItemURL: &trashed)
                    } catch {
                        throw EngineError(.failed, String(localized: "Couldn’t move the old “\(old.lastPathComponent)” to the Trash."))
                    }
                    guard let trashed else { throw PublicationRecovery.retained([old]) }
                    backups.append((old, trashed as URL))
                }
            }
            for attempt in 1..<10_000 {
                if Task.isCancelled { throw EngineError(.cancelled) }
                let stem = attempt == 1 ? name : "\(name) \(attempt)"
                let targets = parts.map { destination.appending(path: stem + $0.1) }
                if targets.contains(where: exists) { continue }
                var published: [(ExclusivePublication.Receipt, URL)] = []
                do {
                    for ((source, _), target) in zip(parts, targets) {
                        let receipt = try await ExclusivePublication.publish(source: source, to: target, options: publicationOptions)
                        published.append((receipt, target))
                    }
                    if Task.isCancelled { throw EngineError(.cancelled) }
                    published.forEach { $0.0.commit() }
                    return targets
                } catch {
                    var retained = PublicationRecovery.paths(in: error, otherwise: [])
                    for (receipt, target) in published.reversed() {
                        do { try await receipt.rollback() }
                        catch { retained += PublicationRecovery.paths(in: error, otherwise: [target]) }
                    }
                    if !retained.isEmpty { throw ExclusivePublication.Failure.rollbackIncomplete(retained) }
                    if case ExclusivePublication.Failure.collision = error { continue }
                    throw PublicationRecovery.engineError(error)
                }
            }
            throw EngineError(.failed, String(localized: "Couldn’t find a free name for “\(name)”."))
        } catch {
            var retained = PublicationRecovery.paths(in: error, otherwise: [])
            for backup in backups.reversed() {
                do { try await PublicationRecovery.restore(backup.trash, to: backup.original) }
                catch { retained += [backup.trash, backup.original] }
            }
            if !retained.isEmpty { throw PublicationRecovery.retained(retained) }
            throw PublicationRecovery.engineError(error)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Handing the files over is the first fifth of the bar; compressing (and checking) the rest.
    private nonisolated final class Meter: Sendable {
        private let total: Int64
        private let onProgress: @Sendable (Double) -> Void
        private let state = Mutex((sent: Int64(0), shown: 0.0))

        init(total: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
            self.total = max(total, 1)
            self.onProgress = onProgress
        }

        func sent(_ bytes: Int64) {
            report { state in
                state.sent += bytes
                return 0.2 * min(1, Double(state.sent) / Double(total))
            }
        }

        func compressed(_ fraction: Double) {
            report { _ in 0.2 + 0.78 * fraction }
        }

        /// Only forward visible steps, so tiny chunks don't flood the main actor.
        private func report(_ next: (inout (sent: Int64, shown: Double)) -> Double) {
            let value: Double? = state.withLock { state in
                let value = next(&state)
                guard value - state.shown >= 0.005 else { return nil }
                state.shown = value
                return value
            }
            if let value { onProgress(value) }
        }
    }
}
