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
        var companion: Node?
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
                    let sourceParent = open(source.deletingLastPathComponent().path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
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
            if let companion = node.companion {
                var companionStatus = stat()
                let result = fstatat(parent, companion.name, &companionStatus, AT_SYMLINK_NOFOLLOW)
                if (result == 0 && companion.fingerprint != Fingerprint(companionStatus)) || (result != 0 && errno != ENOENT) {
                    retained.append(companion.url); retained.append(node.url); return
                }
            }
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
            // Removing a file can implicitly remove its native metadata companion, too.
            if let companion = node.companion {
                var value = stat()
                let result = fstatat(parent, companion.name, &value, AT_SYMLINK_NOFOLLOW)
                guard (result == 0 && companion.fingerprint == Fingerprint(value)) || (result != 0 && errno == ENOENT) else {
                    retained.append(companion.url); retained.append(node.url); return
                }
            }
            // Check again after child cleanup. Never traverse an unknown directory or symlink.
            guard fstatat(parent, node.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  node.fingerprint.owns(current),
                  unlinkat(parent, node.name, directory ? AT_REMOVEDIR : 0) == 0 else {
                retained.append(node.url); return
            }
            if let companion = node.companion { remove(companion, parent: parent, retained: &retained) }
        }
    }

    static func publish(source: URL, to target: URL, options: Options = .init()) async throws -> Receipt {
        let worker = Task.detached { try publishSynchronously(source: source, to: target, options: options) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func publishSynchronously(source: URL, to target: URL, options: Options = .init(), checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Receipt {
        try options.checkCancellation(); try checkCancellation()
        let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw system("open destination", target) }
        var transferred = false
        defer { if !transferred { close(parent) } }
        let sourceParent = open(source.deletingLastPathComponent().path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
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
                     destinationParent: parent, target: target, options: options, checkCancellation: checkCancellation) { root = $0 }
            try options.checkCancellation(); try checkCancellation()
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
                             target: URL, options: Options, checkCancellation: () throws -> Void, created: (Node) -> Void) throws {
        try options.checkCancellation(); try checkCancellation()
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
        var existing = stat()
        if fstatat(destinationParent, targetName, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.collision }
        if errno != ENOENT { throw system("inspect output name", target) }
        var companion: Node?
        if isExFAT(destinationParent), !targetName.hasPrefix("._") {
            let companionName = "._" + targetName
            let companionURL = target.deletingLastPathComponent().appendingPathComponent(companionName)
            let companionFD = openat(destinationParent, companionName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard companionFD >= 0 else {
                if errno == EEXIST { throw Failure.collision }; throw system("reserve metadata companion", companionURL)
            }
            var companionStatus = stat()
            guard fstat(companionFD, &companionStatus) == 0 else {
                close(companionFD); throw system("stat metadata companion", companionURL)
            }
            close(companionFD)
            guard fstatat(destinationParent, companionName, &companionStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw system("stat metadata reservation", companionURL)
            }
            let reservation = Node(name: companionName, url: companionURL, fd: -1, status: companionStatus)
            companion = reservation
            created(reservation)
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
        node.companion = companion
        created(node)
        defer {
            if isExFAT(destinationParent) { _ = fsync(output) }
            var latest = stat()
            if fstat(output, &latest) == 0 { node.fingerprint = Fingerprint(latest) }
            close(output); node.fd = -1
            if let companion {
                if companion.fd >= 0 { close(companion.fd); companion.fd = -1 }
                var final = stat()
                if fstatat(destinationParent, companion.name, &final, AT_SYMLINK_NOFOLLOW) == 0 {
                    companion.fingerprint = Fingerprint(final)
                }
            }
            // FSKit assigns a stable inode to AppleDouble files only once their writer closes.
            var final = stat()
            if targetName.hasPrefix("._"), fstatat(destinationParent, targetName, &final, AT_SYMLINK_NOFOLLOW) == 0 {
                node.fingerprint = Fingerprint(final)
            }
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
                if try isSemanticCompanion(child, parent: input) { continue }
                try copy(name: child, sourceParent: input, targetName: child, destinationParent: output,
                         target: target.appendingPathComponent(child), options: options, checkCancellation: checkCancellation) { node.children.append($0) }
            }
        } else {
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try options.checkCancellation(); try checkCancellation()
                let count = read(input, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw system("read", target) }
                if count == 0 { break }
                var offset = 0
                while offset < count {
                    try options.checkCancellation(); try checkCancellation()
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
        if name.hasPrefix("._"), isExFAT(sourceParent), flistxattr(input, nil, 0, 0) < 0, errno == EPERM {
            // FSKit denies xattr APIs on raw helper files themselves. Their metadata payload is
            // the copied data, including when a helper was explicitly selected as the root.
            guard fchmod(output, opened.st_mode & 0o7777) == 0 else { throw system("copy helper mode", target) }
            var times = [opened.st_atimespec, opened.st_mtimespec]
            guard futimens(output, &times) == 0 else { throw system("copy helper times", target) }
        } else {
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw system("copy metadata", target)
            }
            try verifyExtendedAttributes(input: input, output: output, target: target)
        }
        var finished = stat()
        guard fstat(input, &finished) == 0, Fingerprint(opened) == Fingerprint(finished) else {
            throw Failure.unsupportedSource(path: target.path)
        }
    }

    private static func isExFAT(_ fd: Int32) -> Bool {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return false }
        return withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0).lowercased().contains("exfat")
            }
        }
    }

    /// Only native exFAT metadata companions are interpreted; root helper selections never
    /// enter this path. Ordinary ._ payloads remain real files and retain exclusive collision rules.
    static func isSemanticCompanion(_ name: String, parent: Int32, requireExFAT: Bool = true) throws -> Bool {
        guard name.hasPrefix("._"), !requireExFAT || isExFAT(parent) else { return false }
        let paired = String(name.dropFirst(2))
        let input = openat(parent, paired, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return false }
        defer { close(input) }
        let side = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard side >= 0 else { return false }
        defer { close(side) }
        var status = stat()
        guard fstat(side, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 26, status.st_size <= 64 * 1024 * 1024 else { return false }
        var data = Data(count: Int(status.st_size))
        let count = data.withUnsafeMutableBytes { read(side, $0.baseAddress, $0.count) }
        guard count == data.count, let attributes = AppleDouble.attributes(in: data), !attributes.isEmpty else { return false }
        let namesCount = flistxattr(input, nil, 0, 0)
        guard namesCount > 0, namesCount <= 1024 * 1024 else { return false }
        var names = [CChar](repeating: 0, count: namesCount)
        guard flistxattr(input, &names, namesCount, 0) == namesCount else { return false }
        var start = 0
        var matched = 0
        for end in names.indices where names[end] == 0 {
            let key = String(decoding: names[start..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            start = end + 1
            guard let expected = attributes[key] else { return false }
            var actual = Data(count: max(1, expected.count))
            let size = actual.withUnsafeMutableBytes { fgetxattr(input, key, $0.baseAddress, expected.count, 0, 0) }
            if key == "com.apple.quarantine" {
                // Apple's packed form has a q/ wrapper and NUL padding; getxattr exposes the
                // unwrapped payload. Compare that payload without dropping other attributes.
                var packed = expected
                if packed.starts(with: [0x71, 0x2f]) { packed.removeFirst(2) }
                while packed.last == 0 { packed.removeLast() }
                guard size >= 0 else { return false }
                var live = Data(actual.prefix(size))
                while live.last == 0 { live.removeLast() }
                guard packed == live else { return false }
            } else {
                guard size == expected.count, actual.prefix(size) == expected else { return false }
            }
            matched += 1
        }
        return matched > 0
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
