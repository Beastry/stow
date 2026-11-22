import Foundation

/// What the Quick Look extension shows for an archive in Finder: a header, a one-line Checkup and
/// the file tree. Built from the same `Archive` the browser uses, so names, sizes and findings match.
nonisolated struct ArchivePreviewModel: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let name: String
        let depth: Int
        let isFolder: Bool
        let hasChildren: Bool
        let size: Int64
    }

    var name: String
    var format: ArchiveFormat
    var fileCount: Int
    var folderCount: Int
    var totalSize: Int64
    var packedSize: Int64?
    var isEncrypted: Bool
    var headline: CheckupFinding?
    var cautionCount: Int
    private let children: [String: [ArchiveEntry]]
    private let limit: Int

    struct Visible {
        var rows: [Row] = []
        /// Expanded entries beyond the display budget. Collapsed descendants do not count.
        var hiddenRowCount = 0
    }

    static let rowLimit = 1_500

    init(archive: Archive, rowLimit: Int = Self.rowLimit) {
        name = archive.name
        format = archive.format
        let files = archive.files
        fileCount = files.count
        folderCount = archive.entries.count - files.count
        totalSize = archive.totalSize
        packedSize = archive.packedSize
        isEncrypted = archive.isEncrypted
        headline = Self.headline(of: archive.checkup)
        cautionCount = archive.checkup.count { $0.severity == .caution }

        var children: [String: [ArchiveEntry]] = [:]
        for entry in archive.entries { children[entry.parent, default: []].append(entry) }
        for key in children.keys {
            children[key]?.sort { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        self.children = children
        self.limit = max(0, rowLimit)
    }

    func visible(expanded: Set<String>) -> Visible {
        var result = Visible()
        // Stack frames refer to sibling arrays without copying the whole subtree.
        var stack: [(entries: [ArchiveEntry], index: Int)] = [(children[""] ?? [], 0)]
        var total = children[""]?.count ?? 0
        var visibleFolders: Set<String> = [""]
        // Parents sort before their descendants. Count whole sibling arrays without walking
        // every file when a very wide folder exceeds Quick Look's budget.
        for path in expanded.sorted() {
            let parent = (path as NSString).deletingLastPathComponent
            if visibleFolders.contains(parent), let entries = children[path] {
                visibleFolders.insert(path)
                total += entries.count
            }
        }
        while result.rows.count < limit, let frame = stack.last {
            guard frame.index < frame.entries.count else {
                stack.removeLast()
                continue
            }
            let entry = frame.entries[frame.index]
            let depth = stack.count - 1
            stack[depth].index += 1
            let descendants = entry.isFolder ? children[entry.path] : nil
            result.rows.append(Row(id: entry.path, name: entry.name, depth: depth,
                                   isFolder: entry.isFolder, hasChildren: descendants != nil, size: entry.size))
            if expanded.contains(entry.path), let descendants { stack.append((descendants, 0)) }
        }
        result.hiddenRowCount = total - result.rows.count
        return result
    }

    /// The finding that matters most: a caution, then anything Stow handled, then the rest.
    static func headline(of findings: [CheckupFinding]) -> CheckupFinding? {
        let order: [CheckupFinding.Severity] = [.caution, .handled]
        for severity in order {
            if let finding = findings.first(where: { $0.severity == severity }) { return finding }
        }
        return nil
    }

    /// A larger/equal packed value is not a saving. Keep the raw value without a false "smaller" claim.
    static func packedSummary(packed: Int64, total: Int64) -> String {
        guard total > 0, packed < total else { return String(localized: "\(packed.bytes) packed") }
        let saving = Int(((1 - Double(packed) / Double(total)) * 100).rounded())
        guard saving > 0 else { return String(localized: "\(packed.bytes) packed") }
        return String(localized: "\(packed.bytes) packed · \(saving)% smaller")
    }

    var summary: String {
        var parts = [String(localized: "\(fileCount) files")]
        if folderCount > 0 { parts.append(String(localized: "\(folderCount) folders")) }
        parts.append(totalSize.bytes)
        return parts.joined(separator: " · ")
    }
}

/// What the preview shows instead when listing isn't possible or takes too long.
nonisolated struct ArchivePreviewFallback: Sendable {
    enum Reason: Sendable, Equatable {
        /// Names are encrypted too (7-Zip "encrypt file names"); nothing can be listed without the password.
        case encrypted
        /// Listing took longer than Quick Look should wait — usually a big .tar.xz that must be read end to end.
        case tooSlow
        case unreadable(String)
    }

    var name: String
    var format: ArchiveFormat
    var size: Int64
    var reason: Reason

    var title: String {
        switch reason {
        case .encrypted: String(localized: "Encrypted archive")
        case .tooSlow: String(localized: "Too large to list here")
        case .unreadable: String(localized: "Can’t list this archive")
        }
    }

    var message: String {
        switch reason {
        case .encrypted: String(localized: "Even the file names are protected. Open it in Stow and enter the password to see what’s inside.")
        case .tooSlow: String(localized: "Reading the whole archive would take a while. Open it in Stow to browse while it loads.")
        case .unreadable(let message): message
        }
    }

    var symbol: String {
        switch reason {
        case .encrypted: "lock.fill"
        case .tooSlow: "hourglass"
        case .unreadable: "questionmark.folder"
        }
    }
}

nonisolated enum ArchivePreviewContent: Sendable {
    case listed(ArchivePreviewModel)
    case fallback(ArchivePreviewFallback)
}

/// Lists an archive through the engine, giving up after `timeout`. List only — Quick Look never extracts.
nonisolated enum ArchivePreviewLoader {
    static let timeout: Duration = .seconds(3)

    static func load(_ url: URL, timeout: Duration = Self.timeout,
                     list: @escaping @Sendable (URL) async throws -> ArchiveListing) async throws(CancellationError) -> ArchivePreviewContent {
        if Task.isCancelled { throw CancellationError() }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let format = ArchiveFormat.infer(fromName: url.lastPathComponent) ?? .other
        func fallback(_ reason: ArchivePreviewFallback.Reason) -> ArchivePreviewContent {
            .fallback(ArchivePreviewFallback(name: url.lastPathComponent, format: format, size: size, reason: reason))
        }
        // A provider can reply after the extension switches archives. AsyncStream lets the
        // waiting consumer leave on cancellation even when that provider is still running.
        let (responses, reply) = AsyncStream<Result<ArchiveListing, EngineError>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let listing = Task {
            do { reply.yield(.success(try await list(url))) }
            catch { reply.yield(.failure(EngineError(error))) }
            reply.finish()
        }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            reply.finish()
        }
        defer {
            listing.cancel()
            deadline.cancel()
            reply.finish()
        }
        var iterator = responses.makeAsyncIterator()
        let result = await iterator.next()
        if Task.isCancelled { throw CancellationError() }
        switch result {
        case nil:
            return fallback(.tooSlow)
        case .failure(let error) where error.failure == .passwordRequired || error.failure == .wrongPassword:
            return fallback(.encrypted)
        case .failure(let error):
            return fallback(.unreadable(error.message))
        case .success(let listing):
            return .listed(ArchivePreviewModel(archive: Archive(listing: listing, url: url)))
        }
    }
}
