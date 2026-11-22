import AppKit
import Observation

/// A window's staged edits. Source scopes live as long as the undoable session does.
@Observable
final class EditSession {
    static var rawPathReason: String {
        String(localized: "This name uses an unknown text encoding, so Stow can’t rename or delete it safely.")
    }
    static var changedOnDiskSummary: String {
        String(localized: "This archive changed on disk.")
    }
    private(set) var base: ArchiveListing
    private(set) var identity: FileIdentity?
    private(set) var operations: [EditOperation] = []
    private(set) var staged: [String: URL] = [:]
    private(set) var url: URL?
    private(set) var name: String
    let format: EditableFormat?
    /// Provisional listings must never become an edit base.
    var isListing = false
    /// True once the file on disk no longer matches `identity` (watcher or a failed Save).
    private(set) var changedOnDisk = false
    var displayedPaths: [String: String] = [:]
    var undoManager: UndoManager?
    var onChange: (() -> Void)?
    /// Notified after the archive URL changes (rename or Save a Copy) so AppState can refresh scopes.
    var onURLChange: ((URL) -> Void)?
    var message: String?
    var showsReadOnly = false
    private(set) var isSaving = false
    private(set) var progress = 0.0
    private let rawPaths: [String]
    @ObservationIgnored private var cachedPending: ArchiveListing?
    @ObservationIgnored private var watcher = ArchiveWatcher()
    private var scoped: [URL] = []
    private var transferDirectories: [URL] = []

    func retainTransferDirectory(_ url: URL) { transferDirectories.append(url) }

    private func removeTransferDirectories() {
        for url in transferDirectories { try? FileManager.default.removeItem(at: url) }
        transferDirectories = []
    }

    /// Private export for a drag; the live session, source file and Undo history stay unchanged.
    func copyForTransfer(to destination: URL, password: String?) async throws -> ArchiveListing {
        guard !isSaving, let url else { throw EngineError(.cancelled) }
        try? FileManager.default.removeItem(at: destination)
        return try await ArchiveSaver.saveCopy(from: url, to: destination, operations: operations,
                                               items: packItems(), password: password,
                                               encryptNewItems: true, identity: identity) { _ in }
    }
    private var sourceFiles: [String: [PackFile]] = [:]

    init(base: ArchiveListing, url: URL?, name: String? = nil, nested: Bool = false) {
        self.base = base
        rawPaths = base.entries.filter { $0.rawPath != nil }.map(\.path)
        self.url = url
        let resolvedName = name ?? url?.lastPathComponent ?? "Archive"
        self.name = resolvedName
        format = nested ? nil : EditableFormat(listing: base, fileName: resolvedName)
        identity = url.flatMap { try? FileIdentity(of: $0) }
        if let url { startWatching(url) }
    }

    isolated deinit {
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        watcher.stop()
        removeTransferDirectories()
    }

    var isEdited: Bool { !operations.isEmpty }
    /// Shared command enablement for menus and toolbar controls.
    var canSave: Bool { isEdited && !isSaving && !changedOnDisk }
    var canSaveCopy: Bool { isEdited && !isSaving }
    var canRevert: Bool { isEdited && !isSaving }

    /// Shared Delete command enablement; invocation still explains read-only or path refusals.
    func canDelete(selectionIsEmpty: Bool, archiveOwnsFocus: Bool) -> Bool {
        archiveOwnsFocus && !selectionIsEmpty && !isSaving
    }

    var changeCount: Int { operations.count }
    var summary: String { String(localized: "\(changeCount) unsaved changes") }
    /// Banner: edits pending and the file on disk no longer matches what Stow opened.
    var showsExternalChange: Bool { changedOnDisk && isEdited && !isSaving }

    private var sourceEntries: [ListedEntry] {
        sourceFiles.values.flatMap { $0 }.map {
            ListedEntry(path: $0.path, isFolder: $0.isFolder, isSymlink: $0.isLink, size: $0.size, modified: sourceDates[$0.path])
        }
    }
    /// Added files' modification dates on disk, read once when they're staged.
    private var sourceDates: [String: Date] = [:]
    var pending: ArchiveListing {
        if operations.isEmpty { return base }
        if let cachedPending { return cachedPending }
        let listing = EditPlan.apply(operations, to: base, sources: sourceEntries)
        cachedPending = listing
        return listing
    }

    /// Recognizes the conventional JAR signature metadata without asserting it is valid.
    var hasJARSignature: Bool {
        guard format == .zip, (name as NSString).pathExtension.lowercased() == "jar" else { return false }
        let names = Set(base.entries.compactMap { entry -> String? in
            guard !entry.isFolder, !entry.isSymlink else { return nil }
            let components = entry.path.uppercased().split(separator: "/")
            guard components.count == 2, components[0] == "META-INF" else { return nil }
            return String(components[1])
        })
        return names.contains { name in
            let file = name as NSString
            return ["RSA", "DSA", "EC"].contains(file.pathExtension)
                && names.contains(file.deletingPathExtension + ".SF")
        }
    }

    var readOnlyReason: String {
        let lower = name.lowercased()
        if lower.range(of: #"\.(\d{3,}|z\d+|r\d+)$|(^|\.)part\d+\."#, options: .regularExpression) != nil {
            return String(localized: "Split archives are read-only.")
        }
        if lower.contains(".tar.") || ["tgz", "tbz", "tbz2", "txz"].contains((lower as NSString).pathExtension) {
            return String(localized: "Compressed TAR archives are read-only in Stow for now.")
        }
        if base.type.lowercased().hasPrefix("rar") {
            return String(localized: "“\(name)” is a RAR archive, which Stow can open but not change.")
        }
        return String(localized: "“\(name)” is read-only in Stow. Extract and repack it to make changes.")
    }

    private func startWatching(_ url: URL) {
        watcher.onChange = { [weak self] in
            guard let self, !self.isSaving else { return }
            guard let current = self.url, current.standardizedFileURL == url.standardizedFileURL else { return }
            guard let identity = self.identity else {
                self.markChangedOnDisk()
                return
            }
            if (try? FileIdentity(of: current)) != identity {
                self.markChangedOnDisk()
            }
        }
        watcher.watch(url)
    }

    private func markChangedOnDisk() {
        guard !changedOnDisk else { return }
        changedOnDisk = true
        onChange?()
    }

    /// Snapshot scenes: show Save part-way through, as the progress the engine reports would.
    func showSavingForDemo(progress: Double) {
        isSaving = true
        self.progress = progress
    }

    /// Sample / snapshot scenes have no real file to watch; flip the same flag the watcher would.
    func revealExternalChangeForDemo() {
        markChangedOnDisk()
    }

    @discardableResult func requireEditable() -> Bool {
        guard !isListing else { return false }
        guard format != nil else { showsReadOnly = true; return false }
        return !isSaving
    }

    func refusal(for paths: [String]) -> String? {
        rawPaths.contains { raw in
            paths.contains { Self.contains(displayedPaths[raw] ?? raw, in: $0) }
        } ? Self.rawPathReason : nil
    }

    private func accept(_ operation: EditOperation, action: String) {
        guard requireEditable(), let format else { return }
        do {
            _ = try EditPlan.steps(for: operations + [operation], listing: base, format: format, sources: sourceEntries)
            restore(operations + [operation], action: action)
        } catch { message = error.message }
    }

    private func restore(_ next: [EditOperation], action: String,
                         select: (() -> Void)? = nil, undoSelection: (() -> Void)? = nil) {
        let previous = operations
        let manager = undoManager
        let grouping = manager != nil && manager?.isUndoing == false && manager?.isRedoing == false
        if grouping { manager?.beginUndoGrouping() }
        manager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(previous, action: action, select: undoSelection, undoSelection: select) }
        }
        manager?.setActionName(action)
        cachedPending = nil
        operations = next
        onChange?()
        select?()
        if grouping { manager?.endUndoGrouping() }
    }

    enum ImportResolution { case keepBoth, replace, cancel }

    private struct StagedSource {
        let url: URL
        let files: [PackFile]
        let scoped: Bool

        func releaseScope() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    private func importRoots(in folder: String) -> [String: Set<String>] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var roots: [String: Set<String>] = [:]
        for entry in pending.entries where entry.path.hasPrefix(prefix) {
            guard let name = entry.path.dropFirst(prefix.count).split(separator: "/").first else { continue }
            roots[Self.nameKey(String(name)), default: []].insert(prefix + name)
        }
        return roots
    }

    /// What the collision prompt says (#367): the incoming names that collide, once each; the
    /// names Keep Both will give them (the same numbering `add` uses); whether Replace swaps out a
    /// whole folder; and, for a single clash, the item in the archive and the one coming in.
    struct ImportConflicts {
        struct Existing {
            let isFolder: Bool
            let size: Int64
            let modified: Date
            /// Everything inside, for a folder.
            let itemCount: Int
        }

        var names: [String] = []
        var keptNames: [String] = []
        var replacesFolder = false
        var existing: Existing?
        var incoming: URL?
    }

    func importConflicts(_ urls: [URL], into folder: String) -> ImportConflicts {
        let roots = importRoots(in: folder)
        let incomingNames = urls.map { Self.nameKey($0.lastPathComponent) }
        let reserved = Set(incomingNames)
        var taking = Set(roots.keys), reported = Set<String>()
        var result = ImportConflicts()
        var clashing: [(url: URL, key: String)] = []
        for (url, key) in zip(urls, incomingNames) {
            guard taking.contains(key) else { taking.insert(key); continue }
            clashing.append((url, key))
            if reported.insert(key).inserted { result.names.append(url.lastPathComponent) }
            var attempt = 2
            var name = Compatibility.numbered(url.lastPathComponent, attempt)
            while taking.contains(Self.nameKey(name)) || reserved.contains(Self.nameKey(name)) {
                attempt += 1
                name = Compatibility.numbered(url.lastPathComponent, attempt)
            }
            taking.insert(Self.nameKey(name))
            result.keptNames.append(name)
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.replacesFolder = true
            }
            for path in roots[key] ?? [] where pending.entries.contains(where: {
                ($0.path == path && $0.isFolder) || $0.path.hasPrefix(path + "/")
            }) {
                result.replacesFolder = true
            }
        }
        if clashing.count == 1, let clash = clashing.first, let path = roots[clash.key]?.first {
            let inside = pending.entries.filter { $0.path.hasPrefix(path + "/") }
            let entry = pending.entries.first { $0.path == path }
            if entry != nil || !inside.isEmpty {
                let newestInside: Date = inside.compactMap(\.modified).max() ?? .distantPast
                let modified: Date = entry?.modified ?? newestInside
                result.existing = .init(isFolder: entry?.isFolder ?? true, size: entry?.size ?? 0,
                                        modified: modified, itemCount: inside.count)
            }
            result.incoming = clash.url
        }
        return result
    }

    func importHasConflicts(_ urls: [URL], into folder: String) -> Bool {
        var names = Set(importRoots(in: folder).keys)
        return urls.map { Self.nameKey($0.lastPathComponent) }.filter { !names.insert($0).inserted }.count > 0
    }

    /// A batch uses the supplied order. Explicitly selected ancestor and descendant sources
    /// each get a top-level entry; Replace keeps the last source for each equivalent name.
    @discardableResult
    func add(_ urls: [URL], into folder: String, resolving resolution: ImportResolution = .keepBoth,
             select: ((Set<String>) -> Void)? = nil, undoSelection: (() -> Void)? = nil) -> Bool {
        guard resolution != .cancel, !Task.isCancelled, requireEditable(), !urls.isEmpty else { return false }
        let prefix = folder.isEmpty ? "" : folder + "/"
        guard folder.isEmpty || pending.entries.contains(where: {
            $0.path.hasPrefix(prefix) || ($0.path == folder && $0.isFolder && !$0.isSymlink)
        }) else { return false }

        let roots = importRoots(in: folder)
        var taking = Set(roots.keys)
        let incomingNames = urls.map { Self.nameKey($0.lastPathComponent) }
        let reserved = Set(incomingNames)
        let lastIndex = Dictionary(zip(incomingNames, urls.indices), uniquingKeysWith: { _, later in later })
        var replaced = Set<String>()
        var items: [EditOperation.ImportItem] = []
        var prepared: [String: StagedSource] = [:]
        defer { prepared.values.forEach { $0.releaseScope() } }

        for (index, url) in urls.enumerated() {
            guard !Task.isCancelled else { return false }
            let original = url.lastPathComponent
            var name = original
            let source = UUID().uuidString
            guard let candidate = prepare(url, named: source) else { return false }
            if resolution == .replace {
                guard index == lastIndex[incomingNames[index]] else {
                    candidate.releaseScope()
                    continue
                }
                replaced.formUnion(roots[incomingNames[index]] ?? [])
            } else if taking.contains(incomingNames[index]) {
                var attempt = 2
                name = Compatibility.numbered(original, attempt)
                while taking.contains(Self.nameKey(name)) || reserved.contains(Self.nameKey(name)) {
                    attempt += 1
                    name = Compatibility.numbered(original, attempt)
                }
            }
            taking.insert(Self.nameKey(name))
            items.append(.init(name: name, source: source))
            prepared[source] = candidate
        }

        let paths = Set(items.map { prefix + $0.name })
        let operation = EditOperation.importItems(destinationFolder: folder, items: items, replacing: replaced.sorted())
        guard commit(operation, sources: prepared, action: String(localized: "Add \(items.count) Items"),
                     select: { select?(paths) }, undoSelection: undoSelection) else { return false }
        prepared.removeAll()
        return true
    }

    private func prepare(_ url: URL, named name: String) -> StagedSource? {
        let scoped = url.startAccessingSecurityScopedResource()
        if let files = PackRequest.collectForEditing(url, named: name) {
            return StagedSource(url: url, files: files, scoped: scoped)
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        message = String(localized: "“\(url.lastPathComponent)” couldn’t be read. Choose the file again.")
        return nil
    }

    /// Transfers ownership of the prepared scopes only after the complete plan validates.
    private func commit(_ operation: EditOperation, sources: [String: StagedSource], action: String,
                        select: (() -> Void)? = nil, undoSelection: (() -> Void)? = nil) -> Bool {
        guard !Task.isCancelled, let format else { return false }
        var dates: [String: Date] = [:]
        let entries = sources.values.flatMap(\.files).map { file in
            let modified = try? file.source?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            dates[file.path] = modified
            return ListedEntry(path: file.path, isFolder: file.isFolder, isSymlink: file.isLink, size: file.size, modified: modified)
        }
        do {
            _ = try EditPlan.steps(for: operations + [operation], listing: base, format: format,
                                   sources: sourceEntries + entries)
        } catch {
            message = error.message
            return false
        }
        for (name, source) in sources {
            staged[name] = source.url
            sourceFiles[name] = source.files
            if source.scoped { scoped.append(source.url) }
        }
        sourceDates.merge(dates) { _, new in new }
        restore(operations + [operation], action: action, select: select, undoSelection: undoSelection)
        return true
    }

    func delete(_ paths: [String]) {
        guard requireEditable(), !paths.isEmpty else { return }
        let roots = paths.filter { path in !paths.contains { $0 != path && Self.contains(path, in: $0) } }
        if let reason = refusal(for: roots) { message = reason; return }
        let action = roots.count == 1 ? String(localized: "Delete “\((roots[0] as NSString).lastPathComponent)”") : String(localized: "Delete \(roots.count) Items")
        accept(.delete(paths: roots), action: action)
    }

    func rename(_ path: String, to newName: String) {
        guard requireEditable() else { return }
        if let reason = refusal(for: [path]) { message = reason; return }
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            message = String(localized: "Enter a name without a slash."); return
        }
        let parent = ArchiveEntry.parent(of: path)
        let target = parent.isEmpty ? newName : parent + "/" + newName
        guard target != path else { return }
        guard !pending.entries.contains(where: { $0.path.lowercased() == target.lowercased() }) else {
            message = String(localized: "That name is already taken."); return
        }
        accept(.rename(from: path, to: target), action: String(localized: "Rename"))
    }

    func replace(_ path: String, with url: URL) {
        guard requireEditable() else { return }
        let item = UUID().uuidString
        guard let source = prepare(url, named: item) else { return }
        if !commit(.replace(path: path, item: item), sources: [item: source], action: String(localized: "Replace")) {
            source.releaseScope()
        }
    }

    func revert() {
        guard !isSaving, isEdited else { return }
        restore([], action: String(localized: "Revert"))
    }

    func discardChanges() {
        guard !isSaving else { return }
        cachedPending = nil
        operations = []
        undoManager?.removeAllActions(withTarget: self)
        staged = [:]; sourceFiles = [:]; sourceDates = [:]
        removeTransferDirectories()
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = []
        onChange?()
    }

    private func packItems() -> [TreeStream.Item] {
        let referenced = Set(operations.flatMap { operation -> [String] in
            switch operation {
            case let .add(_, items): items
            case let .importItems(_, items, _): items.map(\.source)
            case let .replace(_, item): [item]
            default: []
            }
        })
        return sourceFiles.filter { referenced.contains($0.key) }.values.flatMap { $0 }.compactMap { file in
            file.source.map { TreeStream.Item(source: $0, path: file.path) }
        }
    }

    private func clearAfterSuccessfulWrite(listing: ArchiveListing, at url: URL) {
        base = listing
        self.url = url
        name = url.lastPathComponent
        identity = try? FileIdentity(of: url)
        changedOnDisk = false
        cachedPending = nil
        operations = []
        undoManager?.removeAllActions(withTarget: self)
        staged = [:]; sourceFiles = [:]; sourceDates = [:]
        removeTransferDirectories()
        for scopedURL in scoped { scopedURL.stopAccessingSecurityScopedResource() }
        scoped = []
        startWatching(url)
        onChange?()
        onURLChange?(url)
    }

    func save(password: String?) async -> Bool {
        guard requireEditable(), isEdited, let url else { return false }
        if changedOnDisk {
            message = String(localized: "The archive changed on disk. Reload it or save a copy.")
            return false
        }
        guard identity != nil else {
            message = String(localized: "The archive changed on disk. Reload it or save a copy.")
            changedOnDisk = true
            onChange?()
            return false
        }
        if ArchiveSaver.needsSiblingStaging(for: url) {
            let parent = url.deletingLastPathComponent()
            guard await FolderAccess.shared.writableFolder(
                parent,
                for: .explained(String(localized: "Stow needs to write a temporary file next to the archive to save your changes."))
            ) != nil else { return false }
        }
        progress = 0
        isSaving = true
        defer { isSaving = false }
        do {
            let listing = try await ArchiveSaver.save(archive: url, operations: operations, items: packItems(),
                password: password, encryptNewItems: true, identity: identity) { [weak self] fraction in
                    Task { @MainActor in self?.progress = fraction }
                }
            clearAfterSuccessfulWrite(listing: listing, at: url)
            return true
        } catch {
            if error.failure == .changedOnDisk {
                changedOnDisk = true
                message = String(localized: "The archive changed on disk. Reload it or save a copy.")
                onChange?()
            } else {
                if error.failure != .cancelled {
                    var failure = Failure(error, .pack, name: url.lastPathComponent)
                    // Retry stays on Save, with the staged plan intact.
                    failure.action = nil
                    _ = await Prompts.explain(failure)
                }
            }
            return false
        }
    }

    /// Discards staged edits and reloads the archive from disk.
    @discardableResult func reload(password: String?) async -> Bool {
        guard !isSaving, let url else { return false }
        do {
            let listing = try await ArchiveEngine.shared.list(url, password: password)
            base = listing
            identity = try? FileIdentity(of: url)
            changedOnDisk = false
            cachedPending = nil
            operations = []
            undoManager?.removeAllActions(withTarget: self)
            staged = [:]; sourceFiles = [:]; sourceDates = [:]
        removeTransferDirectories()
            for scopedURL in scoped { scopedURL.stopAccessingSecurityScopedResource() }
            scoped = []
            startWatching(url)
            onChange?()
            return true
        } catch {
            message = EngineError(error).message
            return false
        }
    }

    /// Writes the pending edits to a new file; the original is left byte-identical.
    @discardableResult func saveCopy(to destination: URL, password: String?) async -> Bool {
        guard requireEditable(), isEdited, let url else { return false }
        progress = 0
        isSaving = true
        defer { isSaving = false }
        do {
            let listing = try await ArchiveSaver.saveCopy(
                from: url, to: destination, operations: operations, items: packItems(),
                password: password, encryptNewItems: true, identity: identity,
                ignoreIdentity: changedOnDisk
            ) { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            clearAfterSuccessfulWrite(listing: listing, at: destination)
            return true
        } catch {
            message = error.message
            return false
        }
    }

    /// Renames the archive file itself (including on SMB/NAS once the parent folder is writable).
    @discardableResult func renameArchive(to newName: String) async -> Bool {
        guard !isListing else { return false }
        guard !isSaving, let url else { return false }
        let parent = url.deletingLastPathComponent()
        guard await FolderAccess.shared.writableFolder(
            parent,
            for: .explained(String(localized: "Stow needs access to this folder to rename the archive."))
        ) != nil else { return false }
        do {
            let destination = try ArchiveSaver.renameArchive(at: url, to: newName)
            self.url = destination
            name = destination.lastPathComponent
            identity = try? FileIdentity(of: destination)
            startWatching(destination)
            onChange?()
            onURLChange?(destination)
            return true
        } catch {
            message = EngineError(error).message
            return false
        }
    }

    func state(for path: String) -> String? {
        var state: String?
        for (index, operation) in operations.enumerated() {
            let tail = Array(operations.dropFirst(index + 1))
            switch operation {
            case let .add(folder, items):
                if items.contains(where: { Self.contains(path, in: Self.map(path: folder.isEmpty ? $0 : folder + "/" + $0, through: tail)) }) { state = String(localized: "New") }
            case let .importItems(folder, items, replacing):
                for item in items {
                    let root = folder.isEmpty ? item.name : folder + "/" + item.name
                    guard Self.contains(path, in: Self.map(path: root, through: tail)) else { continue }
                    let replaced = replacing.contains { Self.nameKey($0) == Self.nameKey(root) }
                    state = replaced ? String(localized: "Replaced") : String(localized: "New")
                }
            case let .rename(_, to):
                if Self.contains(path, in: Self.map(path: to, through: tail)) { state = String(localized: "Renamed") }
            case let .replace(target, _):
                if path == Self.map(path: target, through: tail) { state = String(localized: "Replaced") }
            default: break
            }
        }
        return state
    }

    func source(for path: String) -> URL? {
        var current = path
        for operation in operations.reversed() {
            switch operation {
            case let .rename(from, to): if Self.contains(current, in: to) { current = from + current.dropFirst(to.count) }
            case let .replace(target, item): if current == target { return staged[item] }
            case let .importItems(folder, items, replacing):
                for item in items {
                    let root = folder.isEmpty ? item.name : folder + "/" + item.name
                    if Self.contains(current, in: root), let source = staged[item.source] {
                        let suffix = current.dropFirst(root.count)
                        return suffix.isEmpty ? source : source.appending(path: String(suffix.dropFirst()))
                    }
                }
                if replacing.contains(where: { Self.contains(current, in: $0) }) { return nil }
            case let .delete(paths):
                if paths.contains(where: { Self.contains(current, in: $0) }) { return nil }
            case let .add(folder, items):
                for item in items {
                    let root = folder.isEmpty ? item : folder + "/" + item
                    if Self.contains(current, in: root), let source = staged[item] {
                        let suffix = String(current.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        return suffix.isEmpty ? source : source.appending(path: suffix)
                    }
                }
            default: break
            }
        }
        return nil
    }

    func originalPath(for path: String) -> String {
        operations.reversed().reduce(path) { path, operation in
            if case let .rename(from, to) = operation, Self.contains(path, in: to) { return from + path.dropFirst(to.count) }
            return path
        }
    }

    nonisolated static func contains(_ path: String, in root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    nonisolated static func map(path: String, through operations: [EditOperation]) -> String {
        operations.reduce(path) { path, operation in
            if case let .rename(from, to) = operation, contains(path, in: from) { return to + path.dropFirst(from.count) }
            return path
        }
    }
    nonisolated static func nearestExistingParent(_ path: String, in listing: ArchiveListing) -> String {
        var result = path
        while !result.isEmpty {
            if listing.entries.contains(where: { contains($0.path, in: result) }) { return result }
            result = ArchiveEntry.parent(of: result)
        }
        return ""
    }
    nonisolated enum CloseDecision { case save, discard, cancel }
    nonisolated static func canClose(_ decision: CloseDecision, saved: Bool) -> Bool {
        switch decision { case .save: saved; case .discard: true; case .cancel: false }
    }
}
