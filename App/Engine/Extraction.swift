import Foundation

/// Extracts and audits in private staging before publishing the result:
///
/// 1. The engine extracts and audits inside its own sandbox container (it can't write anywhere else).
/// 2. It streams the result into a private staging folder on the destination's volume and audits again.
/// 3. `Placement` settles conflicts and publishes with an exclusive rename, or a cancellable
///    exclusive copy on unsupported volumes. Partial copy output is visible until commit or rollback.
///
/// The engine's output and the staging folder are removed on success, failure and cancel alike.
enum Extraction {
    struct Options {
        var allFolder = Preferences.ExtractAllFolder.automatic
        /// `__MACOSX`, `._*`, `.DS_Store`, `Thumbs.db`… are left out (see `MacHelperFiles`).
        var skipSystemFiles = true
        var resolve: Placement.Resolver = Placement.keepBoth

        /// From the person's settings; conflicts resolved by `resolve`.
        static func current(resolve: @escaping Placement.Resolver) -> Options {
            let values = Preferences.current
            return Options(allFolder: values.extractAllFolder, skipSystemFiles: values.skipSystemFiles, resolve: resolve)
        }
    }

    struct Result: Sendable {
        var placed: [URL]
        var report: ExtractReport
        var placement = Placement.Result()
        var restoredMetadata = AppleDouble.Restored()
        var passwordCompleted: [String] = []
        var passwordSkipped: [String] = []
        var unplacedZIPEntries: [String] = []

        /// Skipped conflicts or safety-filtered payloads are incomplete extraction. In particular,
        /// a successful engine return is not permission to dispose of the only original (#313).
        var isComplete: Bool {
            passwordSkipped.isEmpty && unplacedZIPEntries.isEmpty && placement.skipped == 0 && report.removedItems.isEmpty && report.removedLinks.isEmpty
        }

        /// Checkup lines for what the audit removed and what Mac details came back.
        var findings: [CheckupFinding] {
            var findings = Checkup.findings(for: report) + Checkup.findings(for: restoredMetadata)
            if !passwordSkipped.isEmpty {
                findings.append(.init(severity: .caution, title: String(localized: "Skipped encrypted items"),
                                      detail: passwordSkipped.joined(separator: "\n")))
            }
            if !unplacedZIPEntries.isEmpty {
                findings.append(.init(severity: .caution, title: String(localized: "Items left out of the extraction"),
                                      detail: unplacedZIPEntries.joined(separator: "\n")))
            }
            if !isComplete, !passwordCompleted.isEmpty {
                findings.append(.init(severity: .info, title: String(localized: "Extracted items"),
                                      detail: passwordCompleted.joined(separator: "\n")))
            }
            return findings
        }
    }

    /// `selection` nil extracts everything (see `Options.allFolder` for where it lands). Selected
    /// items land side by side.
    static func run(_ archive: Archive, selection: [ArchiveEntry]?, to destination: URL, options: Options = Options(),
                    onProgress: @escaping @Sendable (Double) -> Void) async throws(EngineError) -> Result {
        let staged = try await stage(archive, selection: selection, near: destination,
                                     skipSystemFiles: options.skipSystemFiles, onProgress: onProgress)
        defer { staged.discard() }
        return try await publish(staged, archive: archive, to: destination, options: options)
    }

    private static func publish(_ staged: Staged, archive: Archive, to destination: URL,
                                options: Options) async throws(EngineError) -> Result {
        let items = staged.items(allFolder: options.allFolder, folderName: folderName(for: archive))
        guard !items.isEmpty else { throw EngineError(.failed, String(localized: "Nothing was extracted.")) }
        let placement = try await Placement.place(items, in: destination, resolve: options.resolve)
        if let source = archive.source?.url { Quarantine.propagate(from: source, to: placement.added) }
        return Result(placed: placement.placed, report: staged.report, placement: placement,
                      restoredMetadata: staged.restoredMetadata)
    }

    static func partialAdvice(_ result: Result) -> String {
        let retained = String(localized: "The original archive was kept. Review the extracted files before trying again.")
        guard !result.passwordSkipped.isEmpty || !result.unplacedZIPEntries.isEmpty else { return retained }
        return ([retained] + result.findings.filter { $0.severity == .caution || $0.severity == .info }
            .map { $0.title + "\n" + $0.detail }).joined(separator: "\n\n")
    }

    /// Use the fast, transactional path first. An encrypted ZIP can fall back to independent
    /// entries on a password error. Publication still happens once, after every choice is resolved.
    static func run(_ archive: Archive, selection: [ArchiveEntry]?, to destination: URL, options: Options,
                    passwords: PasswordHook, candidates: [String] = [],
                    onProgress: @escaping @Sendable (Double) -> Void) async throws(EngineError) -> Result {
        guard archive.format == .zip, archive.isEncrypted, passwords.isWired else {
            return try await run(archive, selection: selection, to: destination, options: options, onProgress: onProgress)
        }
        do {
            return try await run(archive, selection: selection, to: destination, options: options, onProgress: onProgress)
        } catch let error where error.needsPassword {
            return try await extractZIPEntries(archive, selection: selection, to: destination, options: options,
                                               passwords: passwords, candidates: candidates, onProgress: onProgress)
        }
    }

    private static func extractZIPEntries(_ archive: Archive, selection: [ArchiveEntry]?, to destination: URL,
                                          options: Options, passwords: PasswordHook, candidates: [String],
                                          onProgress: @escaping @Sendable (Double) -> Void) async throws(EngineError) -> Result {
        let selected = selection.flatMap { $0.isEmpty ? nil : topmost($0) }
        let entries = archive.entries + archive.index.helpers.filter { helper in
            !options.skipSystemFiles || (selection ?? []).contains { $0.path == helper.path }
        }
        let parents = Set(entries.map(\.parent))
        let targets = entries.sorted { $0.path < $1.path }.filter { entry in
            (!entry.isFolder || !parents.contains(entry.path)) && (selected?.contains {
                $0.path == entry.path || ($0.isFolder && entry.path.hasPrefix($0.path + "/"))
            } ?? true)
        }
        let stageFolder = try makeStaging(for: destination)
        defer { try? FileManager.default.removeItem(at: stageFolder) }
        let root = stageFolder.appending(path: "Contents", directoryHint: .isDirectory)
        var accepted: [String] = []
        var skipped: [String] = []
        var report = ExtractReport()
        var restored = AppleDouble.Restored()
        var folderAttributes: [URL: [FileAttributeKey: Any]] = [:]
        var remembered = candidates
        if let known = archive.source?.password, !remembered.contains(known) { remembered.insert(known, at: 0) }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            for (index, entry) in targets.enumerated() {
                if Task.isCancelled { throw EngineError(.cancelled) }
                var available = [nil] as [String?]
                available += remembered.map(Optional.some)
                var rejectedManual = false
                while true {
                    let password: String?
                    if available.isEmpty {
                        while passwords.isAsking { try await Task.sleep(for: .milliseconds(40)) }
                        if Task.isCancelled { throw EngineError(.cancelled) }
                        password = await passwords.ask(entry.path, .zipEntry, rejectedManual)
                        if Task.isCancelled { throw EngineError(.cancelled) }
                        guard password != nil else { skipped.append(entry.path); break }
                        rejectedManual = true
                    } else {
                        password = available.removeFirst()
                    }
                    var attempt = archive
                    attempt.source?.password = password
                    do {
                        let part = try await stage(attempt, selection: [entry], near: stageFolder,
                                                   skipSystemFiles: options.skipSystemFiles) { _ in }
                        defer { part.discard() }
                        report.removedLinks += part.report.removedLinks
                        report.removedItems += part.report.removedItems
                        restored.files += part.restoredMetadata.files
                        restored.attributes += part.restoredMetadata.attributes
                        let source = part.url(for: entry)
                        if exists(source) {
                            let target = root.appending(path: entry.path)
                            var parent = root
                            for component in entry.path.split(separator: "/").dropLast() {
                                parent.append(path: String(component))
                                if exists(parent) {
                                    let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                                        throw EngineError(.failed, String(localized: "The ZIP contains conflicting paths."))
                                    }
                                } else {
                                    try manager.createDirectory(at: parent, withIntermediateDirectories: false)
                                    let relative = String(parent.path.dropFirst(root.path.count + 1))
                                    let original = part.root.appending(path: relative)
                                    if let sourceAttributes = try? manager.attributesOfItem(atPath: original.path) {
                                        folderAttributes[parent] = sourceAttributes.filter {
                                            $0.key == .modificationDate || $0.key == .creationDate
                                        }
                                    }
                                }
                            }
                            try manager.moveItem(at: source, to: target)
                            accepted.append(entry.path)
                        }
                        if let password {
                            remembered.removeAll { $0 == password }
                            remembered.insert(password, at: 0)
                        }
                        break
                    } catch let error as EngineError where error.needsPassword {
                        continue
                    }
                }
                onProgress(Double(index + 1) / Double(targets.count))
            }
            if Task.isCancelled { throw EngineError(.cancelled) }
            let audited = try await audit(root)
            report.removedLinks += audited.removedLinks
            report.removedItems += audited.removedItems
            let surviving = accepted.filter { exists(root.appending(path: $0)) }
            let staged = Staged(folder: stageFolder, root: root, selection: selected,
                                report: report, restoredMetadata: restored)
            var result = Result(placed: [], report: report)
            if !surviving.isEmpty {
                for (folder, attributes) in folderAttributes where exists(folder) {
                    try? manager.setAttributes(attributes, ofItemAtPath: folder.path)
                }
                result = try await publish(staged, archive: archive, to: destination, options: options)
            }
            let skippedSources = result.placement.skippedSources.map(\.path)
            result.passwordCompleted = surviving.filter { entry in
                let path = root.appending(path: entry).path
                return !skippedSources.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            result.passwordSkipped = skipped
            let accountedFor = Set(result.passwordCompleted + skipped)
            result.unplacedZIPEntries = targets.map(\.path).filter { !accountedFor.contains($0) }
            return result
        } catch {
            if Task.isCancelled { throw EngineError(.cancelled) }
            throw EngineError(error)
        }
    }

    @concurrent
    static func publishPromise(_ source: URL, to target: URL) async throws(EngineError) {
        do {
            let receipt = try await ExclusivePublication.publish(source: source, to: target)
            receipt.commit()
        } catch ExclusivePublication.Failure.system(let operation, _, EPERM)
            where operation == "exclusive rename" || operation == "open destination" {
            // Finder can grant the promised URL without authorizing directory-relative operations.
            // The exact-path copy refuses existing names. A failed copy may leave a partial item.
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                if (error as? CocoaError)?.code != .fileWriteFileExists, exists(target) {
                    throw PublicationRecovery.retained([target])
                }
                throw PublicationRecovery.engineError(error)
            }
        } catch {
            throw PublicationRecovery.engineError(error)
        }
    }

    /// Extracted and audited, waiting next to `destination` (same volume) to be moved into place.
    struct Staged {
        /// The staging folder; `root` holds the archive's contents.
        let folder: URL
        let root: URL
        let selection: [ArchiveEntry]?
        let report: ExtractReport
        var restoredMetadata = AppleDouble.Restored()

        /// The selected entries as they landed, or the archive's top-level items.
        func items(allFolder: Preferences.ExtractAllFolder, folderName: String) -> [(URL, String)] {
            if let selection {
                return selection
                    .map { (root.appending(path: $0.path), $0.name) }
                    .filter { Extraction.exists($0.0) }
            }
            let top = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            guard !top.isEmpty else { return [] }
            if top.count == 1 {
                let only = top[0]
                let alreadyNamed = only.lastPathComponent == folderName && Placement.isPlainFolder(only)
                if allFolder == .automatic || alreadyNamed { return [(only, only.lastPathComponent)] }
            }
            return [(root, folderName)]
        }

        func url(for entry: ArchiveEntry) -> URL { root.appending(path: entry.path) }

        func discard() { try? FileManager.default.removeItem(at: folder) }
    }

    /// Extracts into a staging folder on `destination`'s volume and audits it there.
    static func stage(_ archive: Archive, selection: [ArchiveEntry]?, near destination: URL, skipSystemFiles: Bool = true,
                      onProgress: @escaping @Sendable (Double) -> Void) async throws(EngineError) -> Staged {
        guard let source = archive.source else { throw EngineError(.failed, String(localized: "This archive isn’t on disk.")) }
        // Keep explicit helper intent even when a selected ordinary parent covers that entry.
        let explicitHelpers = (selection ?? []).filter { MacHelperFiles.isInsideHelper($0.path) }
        let preservedHelpers = archive.storedPaths(for: explicitHelpers)
        let selection = selection.flatMap { $0.isEmpty ? nil : topmost($0) }
        // A Mac's AppleDouble files come along so their details can be put back (always: they're
        // the files' own details, not clutter). The engine reads them; the files themselves can't
        // cross over, since sandboxed directory listings hide `._` names.
        let restoreMetadata = !archive.appleDoublePaths.isEmpty
        var paths = selection.map(archive.storedPaths(for:)) ?? []
        if !paths.isEmpty { paths = Array(Set(paths + preservedHelpers)).sorted() }
        if restoreMetadata, !paths.isEmpty { paths += appleDoubles(for: paths, in: archive.appleDoublePaths) }
        let engine = ArchiveEngine.shared
        let output = try await engine.extract(
            source.url, paths: paths, password: source.password, excludeMacHelperFiles: skipSystemFiles,
            preservedHelperPaths: preservedHelpers, restoreMacMetadata: restoreMetadata,
            onProgress: onProgress)
        defer { engine.discard(output) }
        if Task.isCancelled { throw EngineError(.cancelled) }

        let folder = try makeStaging(for: destination)
        let root = folder.appending(path: "Contents", directoryHint: .isDirectory)
        do {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            } catch {
                throw EngineError(.failed, error.localizedDescription)
            }
            try await engine.receive(output, into: root)
            if Task.isCancelled { throw EngineError(.cancelled) }
            // Names 7-Zip decoded with the wrong code page get the names shown in the browser.
            LegacyNames.repair(source.renamed, in: root)
            // A disk image's window dressing (background art, volume icon, the Applications alias)
            // only means something in Finder's window for that image.
            // Someone who chose one of them on purpose gets it.
            let chosen = (selection ?? []).map(\.path)
            for extra in archive.installerExtras
            where !chosen.contains(where: { $0 == extra || $0.hasPrefix(extra + "/") }) {
                try? FileManager.default.removeItem(at: root.appending(path: extra))
            }
            let restored = AppleDouble.apply(output.report.macMetadata, in: root)
            var report = output.report
            report.macMetadata = [:]
            let second = try await audit(root)
            report.removedLinks += second.removedLinks.filter { !report.removedLinks.contains($0) }
            report.removedItems += second.removedItems.filter { !report.removedItems.contains($0) }
            return Staged(folder: folder, root: root, selection: selection, report: report, restoredMetadata: restored)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw EngineError(error)
        }
    }

    /// Inside the destination itself: publication stays on that volume, and — because the person chose
    /// that folder — what Stow writes there isn't marked "created by a sandboxed app, may not run"
    /// (see `com.apple.security.files.user-selected.executable` in App/Stow.entitlements). Staged
    /// in Stow's container instead, extracted apps and packages would refuse to open.
    /// Falls back to the system's replacement folder on volumes where that isn't possible.
    private static func makeStaging(for destination: URL) throws(EngineError) -> URL {
        let inside = destination.appending(path: ".stow-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        if (try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)) != nil {
            return inside
        }
        do {
            return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: destination, create: true)
        } catch {
            throw EngineError(.failed, error.localizedDescription)
        }
    }

    /// Stow doesn't take the engine's word for it.
    @concurrent
    private static func audit(_ root: URL) async throws(EngineError) -> PathContainment.Audit {
        do {
            return try PathContainment.audit(staging: root)
        } catch {
            throw EngineError(.failed, error.localizedDescription)
        }
    }

    /// "Report.pdf" → "Report 2.pdf"; folders and extensionless names just get the number.
    static func numbered(_ name: String, _ attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty || stem.isEmpty ? "\(name) \(attempt)" : "\(stem) \(attempt).\(ext)"
    }

    /// "Harbor Handoff.zip" → "Harbor Handoff"; "logs.tar.gz" → "logs".
    static func folderName(for archive: Archive) -> String {
        let name = archive.name
        for suffix in [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// The AppleDouble companions (`__MACOSX/dir/._name`, `dir/._name`) of the given stored paths.
    /// A selected folder also brings the `__MACOSX` companions of everything inside it: those live
    /// outside the folder, so extracting the folder alone would leave its files' details behind
    /// (inline `dir/._name` companions come with the folder anyway).
    static func appleDoubles(for paths: [String], in available: Set<String>) -> [String] {
        var seen = Set<String>()
        return paths.flatMap { path -> [String] in
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let name = (trimmed as NSString).lastPathComponent
            let parent = (trimmed as NSString).deletingLastPathComponent
            let inline = parent.isEmpty ? "._\(name)" : "\(parent)/._\(name)"
            let inside = "__MACOSX/" + trimmed + "/"
            let nested = available.filter { $0.hasPrefix(inside) }.sorted()
            return ([inline, "__MACOSX/" + inline].filter(available.contains) + nested).filter { seen.insert($0).inserted }
        }
    }

    /// Drops entries already covered by a selected folder.
    private static func topmost(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        let folders = entries.filter(\.isFolder).map { $0.path + "/" }
        return entries.filter { entry in !folders.contains { entry.path.hasPrefix($0) } }
    }

    /// Without following links: a staged link pointing at a sibling still counts.
    nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
