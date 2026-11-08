import Foundation
import Darwin

/// Publishes without replacing an existing name. The compatibility copy is visible while it is
/// written; it is not an atomic publication. Source staging must remain private until commit.
nonisolated enum ExclusivePublication {
    enum Failure: Error, Sendable {
        case collision
        case system(operation: String, path: String, code: Int32)
        case unsupportedSource(path: String)
        case rollbackIncomplete([URL])
    }

    struct Options: Sendable {
        var forceCopy = false
        var checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
        /// Deterministic test seam; called on the worker, after each bounded write.
        var didCopyChunk: (@Sendable (Int) throws -> Void)?
    }

    fileprivate struct Fingerprint: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
        func owns(_ value: stat) -> Bool {
            device == value.st_dev && inode == value.st_ino && mode & S_IFMT == value.st_mode & S_IFMT
        }
    }

    fileprivate final class Node: @unchecked Sendable {
        let name: String
        let url: URL
        var fd: Int32
        var fingerprint: Fingerprint
        var children: [Node] = []
        init(name: String, url: URL, fd: Int32, status: stat) {
            self.name = name; self.url = url; self.fd = fd
            fingerprint = Fingerprint(status)
        }
        deinit { if fd >= 0 { close(fd) } }
    }

    /// Keep receipts until the whole placement transaction commits. Rollback is conservative:
    /// changed files and foreign children are retained and reported, never recursively removed.
    /// POSIX has no inode-conditional unlink: this protects observed replacements, but cannot
    /// eliminate a hostile replacement between the final identity check and unlinkat.
    final class Receipt: @unchecked Sendable {
        let usedCopyFallback: Bool
        private let source: URL
        private let target: URL
        private let parentIdentity: Fingerprint
        private let node: Node
        private let lock = NSLock()
        private var consumed = false
        fileprivate init(source: URL, target: URL, parentFD: Int32, node: Node, copied: Bool) {
            self.source = source; self.target = target
            var parentStatus = stat()
            precondition(fstat(parentFD, &parentStatus) == 0)
            parentIdentity = Fingerprint(parentStatus)
            close(parentFD)
            self.node = node; usedCopyFallback = copied
        }
        func commit() { lock.withLock { consumed = true } }
        func rollback() async throws {
            try await Task.detached { try self.rollbackSynchronously() }.value
        }
        func rollbackSynchronously() throws {
            try lock.withLock {
                guard !consumed else { return }
                let parentFD = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parentFD >= 0 else { throw Failure.rollbackIncomplete([target]) }
                defer { close(parentFD) }
                var parentStatus = stat()
                guard fstat(parentFD, &parentStatus) == 0, parentIdentity.owns(parentStatus) else {
                    throw Failure.rollbackIncomplete([target])
                }
                if !usedCopyFallback {
                    let sourceParent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard sourceParent >= 0 else { throw Failure.rollbackIncomplete([target]) }
                    defer { close(sourceParent) }
                    var current = stat()
                    guard fstatat(parentFD, node.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          node.fingerprint == Fingerprint(current),
                          renameatx_np(parentFD, node.name, sourceParent, source.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                        throw Failure.rollbackIncomplete([target])
                    }
                } else {
                    var retained: [URL] = []
                    Self.remove(node, parent: parentFD, retained: &retained)
                    guard retained.isEmpty else { throw Failure.rollbackIncomplete(retained) }
                }
                consumed = true
            }
        }
        fileprivate static func remove(_ node: Node, parent: Int32, retained: inout [URL]) {
            var current = stat()
            guard fstatat(parent, node.name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { retained.append(node.url) }; return
            }
            guard node.fingerprint.owns(current) else { retained.append(node.url); return }
            let directory = current.st_mode & S_IFMT == S_IFDIR
            if directory {
                let directoryFD = openat(parent, node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directoryFD >= 0 else { retained.append(node.url); return }
                defer { close(directoryFD) }
                var opened = stat()
                guard fstat(directoryFD, &opened) == 0, node.fingerprint.owns(opened) else {
                    retained.append(node.url); return
                }
                for child in node.children.reversed() { remove(child, parent: directoryFD, retained: &retained) }
            } else if node.fingerprint != Fingerprint(current) {
                retained.append(node.url); return
            }
            // Check again after child cleanup. Never traverse an unknown directory or symlink.
            guard fstatat(parent, node.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  node.fingerprint.owns(current),
                  unlinkat(parent, node.name, directory ? AT_REMOVEDIR : 0) == 0 else {
                retained.append(node.url); return
            }
        }
    }

    static func publish(source: URL, to target: URL, options: Options = .init()) async throws -> Receipt {
        let worker = Task.detached { try publishSynchronously(source: source, to: target, options: options) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func publishSynchronously(source: URL, to target: URL, options: Options = .init(), checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Receipt {
        var options = options
        let originalCheck = options.checkCancellation
        options.checkCancellation = { try originalCheck(); try checkCancellation() }
        try options.checkCancellation()
        let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw system("open destination", target) }
        var transferred = false
        defer { if !transferred { close(parent) } }
        let sourceParent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceParent >= 0 else { throw system("open source parent", source) }
        defer { close(sourceParent) }
        if !options.forceCopy {
            if renameatx_np(sourceParent, source.lastPathComponent, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 {
                var status = stat()
                guard fstatat(parent, target.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw system("stat published item", target)
                }
                let node = Node(name: target.lastPathComponent, url: target, fd: -1, status: status)
                transferred = true
                return Receipt(source: source, target: target, parentFD: parent, node: node, copied: false)
            }
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { throw Failure.collision }
            guard code == ENOTSUP || code == EXDEV else { throw system("exclusive rename", target, code) }
        }
        var root: Node?
        do {
            try copy(name: source.lastPathComponent, sourceParent: sourceParent, targetName: target.lastPathComponent,
                     destinationParent: parent, target: target, options: options) { root = $0 }
            try options.checkCancellation()
        } catch {
            if let root {
                var retained: [URL] = []
                Receipt.remove(root, parent: parent, retained: &retained)
                if !retained.isEmpty { throw Failure.rollbackIncomplete(retained) }
            }
            throw error
        }
        transferred = true
        return Receipt(source: source, target: target, parentFD: parent, node: root!, copied: true)
    }

    private static func copy(name: String, sourceParent: Int32, targetName: String, destinationParent: Int32,
                             target: URL, options: Options, created: (Node) -> Void) throws {
        try options.checkCancellation()
        var status = stat()
        guard fstatat(sourceParent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw system("stat source", target) }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw Failure.unsupportedSource(path: target.path) }
        let input = openat(sourceParent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0))
        guard input >= 0 else { throw system("open source", target) }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, Fingerprint(status) == Fingerprint(opened) else {
            throw Failure.unsupportedSource(path: target.path)
        }
        let output: Int32
        if kind == S_IFDIR {
            guard mkdirat(destinationParent, targetName, 0o700) == 0 else {
                if errno == EEXIST { throw Failure.collision }; throw system("create directory", target)
            }
            output = openat(destinationParent, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            output = openat(destinationParent, targetName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard output >= 0 else {
            if errno == EEXIST { throw Failure.collision }; throw system("create output", target)
        }
        var initial = stat()
        guard fstat(output, &initial) == 0 else { close(output); throw system("stat output", target) }
        let node = Node(name: targetName, url: target, fd: output, status: initial)
        created(node)
        defer {
            var latest = stat()
            if fstat(output, &latest) == 0 { node.fingerprint = Fingerprint(latest) }
            close(output); node.fd = -1
        }
        if kind == S_IFDIR {
            guard let directory = fdopendir(dup(input)) else { throw system("read directory", target) }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw system("read directory", target) }; break
                }
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                try copy(name: child, sourceParent: input, targetName: child, destinationParent: output,
                         target: target.appendingPathComponent(child), options: options) { node.children.append($0) }
            }
        } else {
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try options.checkCancellation()
                let count = read(input, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw system("read", target) }
                if count == 0 { break }
                var offset = 0
                while offset < count {
                    try options.checkCancellation()
                    let written = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                    if written < 0 { if errno == EINTR { continue }; throw system("write", target) }
                    guard written > 0 else { throw system("write", target, EIO) }
                    offset += written
                }
                try options.didCopyChunk?(count)
            }
        }
        // Includes modes, timestamps, ACLs, resource forks and extended attributes. Unsupported
        // metadata is a failure, rather than silently losing an audited staging tree's metadata.
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw system("copy metadata", target)
        }
        try verifyExtendedAttributes(input: input, output: output, target: target)
        var finished = stat()
        guard fstat(input, &finished) == 0, Fingerprint(opened) == Fingerprint(finished) else {
            throw Failure.unsupportedSource(path: target.path)
        }
    }

    /// copyfile can report success when a destination ignores an attribute. Verify every source
    /// attribute byte-for-byte before accepting publication, including resource forks.
    private static func verifyExtendedAttributes(input: Int32, output: Int32, target: URL) throws {
        let count = flistxattr(input, nil, 0, 0)
        guard count >= 0 else { throw system("list source metadata", target) }
        if count == 0 { return }
        guard count <= 1024 * 1024 else { throw system("metadata too large", target, E2BIG) }
        var names = [CChar](repeating: 0, count: count)
        guard flistxattr(input, &names, names.count, 0) == count else { throw system("list source metadata", target) }
        var start = 0
        for end in names.indices where names[end] == 0 {
            let name = names[start..<end].map { UInt8(bitPattern: $0) }
            let key = String(decoding: name, as: UTF8.self)
            start = end + 1
            let size = fgetxattr(input, key, nil, 0, 0, 0)
            guard size >= 0, size <= 64 * 1024 * 1024 else { throw system("read source metadata", target, E2BIG) }
            guard fgetxattr(output, key, nil, 0, 0, 0) == size else { throw system("verify output metadata", target, EIO) }
            var sourceValue = [UInt8](repeating: 0, count: max(1, size))
            var outputValue = [UInt8](repeating: 0, count: max(1, size))
            guard fgetxattr(input, key, &sourceValue, size, 0, 0) == size,
                  fgetxattr(output, key, &outputValue, size, 0, 0) == size,
                  sourceValue == outputValue else { throw system("verify output metadata", target, EIO) }
        }
    }

    private static func system(_ operation: String, _ url: URL, _ code: Int32 = errno) -> Failure {
        .system(operation: operation, path: url.path, code: code)
    }
}
