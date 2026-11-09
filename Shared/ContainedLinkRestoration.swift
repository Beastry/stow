import Foundation

/// A capability for one initially empty extraction directory. Restores only independently
/// verified archive links after 7-Zip exits; never follows a symlink while opening their parents.
nonisolated final class ContainedLinkRestoration {
    private let descriptor: Int32
    private let directory: URL

    init?(in directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path), names.isEmpty else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.directory = directory
    }

    deinit { close(descriptor) }

    /// Diagnostics are suggestions, not authority. `verified` contains unique listed symlinks
    /// whose actual archived bytes matched the reported target. Unverified files stay untouched.
    func finish(_ refused: [RemovedLink], verified: Set<RemovedLink>) -> [RemovedLink] {
        var held = stat(), current = stat()
        guard fstat(descriptor, &held) == 0, lstat(directory.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino else { return refused }
        let counts = Dictionary(grouping: refused, by: { Self.collisionKey($0.path) })
        var pending = refused.filter { verified.contains($0) && counts[Self.collisionKey($0.path)]?.count == 1 }
        var restored = Set<RemovedLink>()
        // A link can depend on a later refused link. Keep their placeholders unavailable as
        // targets until restored; cycles and chains ending at rejected links never become ready.
        var unavailable = Set(refused.map { Self.collisionKey($0.path) })
        while !pending.isEmpty {
            var changed = false
            pending.removeAll { link in
                guard !link.target.isEmpty, !link.target.hasPrefix("/"), !link.target.contains("\0"),
                      !PathContainment.linkEscapes(linkPath: link.path, target: link.target),
                      let parent = parent(of: link.path) else { return false }
                defer { close(parent.descriptor) }
                guard let before = placeholder(at: parent),
                      targetExists(link, unavailable: unavailable),
                      let after = placeholder(at: parent), before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino,
                      unlinkat(parent.descriptor, parent.name, 0) == 0,
                      symlinkat(link.target, parent.descriptor, parent.name) == 0 else { return false }
                restored.insert(link)
                unavailable.remove(Self.collisionKey(link.path))
                changed = true
                return true
            }
            if !changed { break }
        }
        // Remove only owned, verified placeholders. Colliding or untrusted files are never removed.
        for link in pending {
            guard let parent = parent(of: link.path) else { continue }
            defer { close(parent.descriptor) }
            if placeholder(at: parent) != nil { _ = unlinkat(parent.descriptor, parent.name, 0) }
        }
        return refused.filter { !restored.contains($0) }
    }

    static func collisionKey(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private struct Parent {
        let descriptor: Int32
        let name: String
    }

    private func parent(of path: String) -> Parent? {
        guard !path.isEmpty, !path.contains("\0"), !path.contains(where: \.isNewline),
              path.utf8.count <= 4_096, PathContainment.containedPath(for: path) == path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var parent = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else { return nil }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parent)
            guard next >= 0 else { return nil }
            parent = next
        }
        return Parent(descriptor: parent, name: name)
    }

    private func placeholder(at parent: Parent) -> stat? {
        var info = stat()
        guard fstatat(parent.descriptor, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size == 0, info.st_nlink == 1,
              info.st_uid == geteuid() else { return nil }
        return info
    }

    /// Resolve every component through directory handles, including components before `..`.
    /// Absolute links, escaping prefixes, missing targets, devices and cycles are rejected.
    private func targetExists(_ link: RemovedLink, unavailable: Set<String>) -> Bool {
        var queue = link.path.split(separator: "/").dropLast().map(String.init)
        queue += link.target.split(separator: "/").map(String.init)
        var handles = [descriptor]
        var names: [String] = []
        defer { handles.dropFirst().forEach { close($0) } }
        var links = 0, components = 0
        while !queue.isEmpty {
            components += 1
            guard components <= 4_096 else { return false }
            let component = queue.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard handles.count > 1 else { return false }
                close(handles.removeLast())
                names.removeLast()
                continue
            }
            let relative = (names + [component]).joined(separator: "/")
            guard !unavailable.contains(Self.collisionKey(relative)) else { return false }
            var info = stat()
            let parent = handles.last!
            guard fstatat(parent, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                links += 1
                guard links <= 40 else { return false }
                var bytes = [UInt8](repeating: 0, count: 4_097)
                let count = readlinkat(parent, component, &bytes, bytes.count)
                guard count > 0, count <= 4_096,
                      let target = String(bytes: bytes.prefix(count), encoding: .utf8),
                      !target.hasPrefix("/"), !target.contains("\0") else { return false }
                queue = target.split(separator: "/").map(String.init) + queue
            case S_IFDIR:
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { return false }
                handles.append(next)
                names.append(component)
            case S_IFREG:
                return queue.isEmpty
            default:
                return false
            }
        }
        return true
    }
}
