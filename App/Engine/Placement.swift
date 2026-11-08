import Foundation

/// Moves finished, staged items into the destination — and decides what happens when a name is
/// already taken there. Every step is journaled; if anything fails or is stopped, everything done so
/// far is put back, including files that were replaced (they went to the Trash, not away).
enum Placement {
    enum Resolution: Sendable, Equatable { case merge, keepBoth, replace, skip }

    struct Conflict: Sendable {
        let name: String
        let existing: URL
        let incoming: URL
        /// Both are plain folders (not packages like `.app`), so they can be merged.
        let canMerge: Bool
    }

    /// Asked once per conflict; throwing (`.cancelled`) stops and undoes the whole placement.
    typealias Resolver = (Conflict) async throws(EngineError) -> Resolution

    struct Result: Sendable {
        /// Top-level items as they ended up; a merged folder is the existing one.
        var placed: [URL] = []
        /// Everything that was moved in (merged folders contribute their new children, not themselves).
        var added: [URL] = []
        var merged = 0
        var replaced = 0
        var skipped = 0
        var usedCopyFallback = false
    }

    /// Stow's behaviour before there were choices: never touch what's there, number the new one.
    static let keepBoth: Resolver = { _ in .keepBoth }

    static func place(_ items: [(URL, String)], in destination: URL,
                      resolve: @escaping Resolver = keepBoth,
                      publicationOptions: ExclusivePublication.Options = .init()) async throws(EngineError) -> Result {
        let run = Run(resolve: resolve, publicationOptions: publicationOptions)
        do {
            for (item, name) in items {
                if let url = try await place(item, named: name, in: destination, run) {
                    run.result.placed.append(url)
                }
            }
            if Task.isCancelled { throw EngineError(.cancelled) }
        } catch {
            let retained = PublicationRecovery.paths(in: error, otherwise: []) + (await run.undo())
            if !retained.isEmpty { throw PublicationRecovery.retained(retained) }
            throw PublicationRecovery.engineError(error)
        }
        run.result.added = run.movedIn
        run.commit()
        return run.result
    }

    private static func place(_ item: URL, named name: String, in folder: URL, _ run: Run) async throws -> URL? {
        let target = folder.appending(path: name)
        if try await run.move(item, to: target) { return target }

        let conflict = Conflict(name: name, existing: target, incoming: item,
                                canMerge: isPlainFolder(item) && isPlainFolder(target))
        var resolution = try await run.resolve(conflict)
        if resolution == .merge, !conflict.canMerge { resolution = .keepBoth }
        if Task.isCancelled { throw EngineError(.cancelled) }

        switch resolution {
        case .merge:
            run.result.merged += 1
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: nil, options: [])
            } catch { throw EngineError(error) }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                _ = try await place(child, named: child.lastPathComponent, in: target, run)
            }
            return target
        case .keepBoth:
            for attempt in 2...10_000 {
                let numbered = folder.appending(path: Extraction.numbered(name, attempt))
                if try await run.move(item, to: numbered) { return numbered }
            }
            throw EngineError(.failed, String(localized: "Couldn’t find a free name for “\(name)”."))
        case .replace:
            try await run.replace(target, with: item)
            run.result.replaced += 1
            return target
        case .skip:
            run.result.skipped += 1
            return nil
        }
    }

    /// A real folder — not a link, not a bundle that only looks like one in Finder.
    static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
    }

    private final class Run {
        enum Step {
            case published(ExclusivePublication.Receipt, URL)
            case trashed(original: URL, inTrash: URL)
        }

        let resolve: Resolver
        let publicationOptions: ExclusivePublication.Options
        var result = Result()
        private var steps: [Step] = []

        init(resolve: @escaping Resolver, publicationOptions: ExclusivePublication.Options) {
            self.resolve = resolve
            self.publicationOptions = publicationOptions
        }

        /// Prefer atomic publication; unsupported volumes use cancellable exclusive copying.
        func move(_ item: URL, to target: URL) async throws -> Bool {
            do {
                let receipt = try await ExclusivePublication.publish(source: item, to: target, options: publicationOptions)
                steps.append(.published(receipt, target))
                result.usedCopyFallback = result.usedCopyFallback || receipt.usedCopyFallback
                return true
            } catch ExclusivePublication.Failure.collision {
                return false
            }
        }

        /// Keep the original in Trash, outside disposable staging, until publication is committed.
        /// If Trash is unavailable, fail without changing the original.
        func replace(_ target: URL, with item: URL) async throws {
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: target, resultingItemURL: &trashed)) != nil, let trashed {
                steps.append(.trashed(original: target, inTrash: trashed as URL))
                guard try await move(item, to: target) else {
                    throw EngineError(.failed, String(localized: "“\(target.lastPathComponent)” reappeared while it was being replaced."))
                }
                return
            }
            throw EngineError(.failed, String(localized: "Couldn’t move the old “\(target.lastPathComponent)” to the Trash."))
        }

        var movedIn: [URL] {
            steps.compactMap { step in
                if case .published(_, let to) = step { to } else { nil }
            }
        }

        func commit() {
            for step in steps {
                if case .published(let receipt, _) = step { receipt.commit() }
            }
            steps.removeAll()
        }

        /// Rollback ignores the cancelled operation's task flag and preserves changed outputs.
        func undo() async -> [URL] {
            var retained: [URL] = []
            for step in steps.reversed() {
                switch step {
                case .published(let receipt, let target):
                    do { try await receipt.rollback() }
                    catch { retained += PublicationRecovery.paths(in: error, otherwise: [target]) }
                case .trashed(let original, let inTrash):
                    do { try await PublicationRecovery.restore(inTrash, to: original) }
                    catch { retained += [inTrash, original] }
                }
            }
            steps.removeAll()
            return retained
        }
    }
}
