import Foundation
import Darwin

/// Stow writes byte-split archives (`name.zip.001`, `name.7z.001`). Reassemble only
/// explicitly readable siblings; never pass a directory capability into the engine.
nonisolated enum SplitArchive {
    /// A number of parts people may ask for (#322): three-digit part names end at .999.
    static let partCountRange = 2...999
    /// No part is smaller than this, as with a custom part size: a tiny archive gets fewer parts.
    static let minimumPartBytes: Int64 = 1_024

    /// How many parts `count` gives an archive of `total` bytes: fewer when parts would fall
    /// under `minimumPartBytes`, never fewer than one.
    static func partCount(total: Int64, requested count: Int) -> Int {
        let wanted = min(max(count, 1), partCountRange.upperBound)
        return Int(min(Int64(wanted), max(1, total / minimumPartBytes)))
    }

    /// The parts' sizes, in order: as equal as bytes allow, the first ones one byte larger when
    /// `total` doesn't divide evenly. They always add up to `total`.
    static func partSizes(total: Int64, requested count: Int) -> [Int64] {
        guard total > 0 else { return [] }
        let parts = Int64(partCount(total: total, requested: count))
        let base = total / parts, extra = total % parts
        return (0..<parts).map { base + ($0 < extra ? 1 : 0) }
    }

    /// Cuts `archive` into "name.001", "name.002"… beside it and removes it (#322). The same byte
    /// split 7-Zip's `-v` writes, so the parts open the same way. On failure or cancellation the
    /// parts written so far are removed and the archive is left as it was.
    @concurrent
    static func split(_ archive: URL, into count: Int) async throws(EngineError) {
        let path = archive.path
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw EngineError(.failed, String(localized: "7-Zip didn’t write an archive."))
        }
        let sizes = partSizes(total: Int64(info.st_size), requested: count)
        var written: [URL] = []
        do {
            let input = try FileHandle(forReadingFrom: archive)
            defer { try? input.close() }
            for (index, size) in sizes.enumerated() {
                let part = URL(filePath: path + "." + String(format: "%03d", index + 1))
                let fd = Darwin.open(part.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw EngineError(.failed, String(cString: strerror(errno))) }
                written.append(part)
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? output.close() }
                var remaining = size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let bytes = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                    guard !bytes.isEmpty else { throw EngineError(.failed, String(localized: "The archive ended early while it was being split.")) }
                    try output.write(contentsOf: bytes)
                    remaining -= Int64(bytes.count)
                }
            }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: archive)
        } catch {
            for part in written { try? FileManager.default.removeItem(at: part) }
            if error is CancellationError { throw EngineError(.cancelled) }
            throw error as? EngineError ?? EngineError(error)
        }
    }

    static func baseName(_ name: String) -> String? {
        let suffix = (name as NSString).pathExtension
        guard suffix.count >= 3, suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              Int(suffix) != nil else { return nil }
        let base = (name as NSString).deletingPathExtension
        guard ["zip", "7z"].contains((base as NSString).pathExtension.lowercased()) else { return nil }
        return base
    }

    static func parts(for first: URL) throws -> [URL] {
        guard let base = baseName(first.lastPathComponent), Int(first.pathExtension) == 1 else {
            throw EngineError(.missingVolume)
        }
        let folder = first.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let parts = siblings.filter { baseName($0.lastPathComponent) == base }
            .sorted { (Int($0.pathExtension) ?? 0) < (Int($1.pathExtension) ?? 0) }
        guard !parts.isEmpty else { throw EngineError(.missingVolume) }
        for (index, part) in parts.enumerated() {
            guard Int(part.pathExtension) == index + 1,
                  part.lastPathComponent == base + "." + String(format: "%0*d", first.pathExtension.count, index + 1) else {
                throw EngineError(.missingVolume)
            }
        }
        return parts
    }

    /// Bounded-memory assembly off the main actor. Unlink immediately: cancellation, errors,
    /// connection loss and process exit cannot leave a named copy of an encrypted archive.
    @concurrent
    static func open(_ parts: [URL]) async throws(EngineError) -> FileHandle {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "stow-volumes-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EngineError(.failed, String(cString: strerror(errno))) }
        let readFD = Darwin.open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        unlink(temporary.path)
        guard readFD >= 0 else {
            close(fd)
            throw EngineError(.failed, String(cString: strerror(errno)))
        }
        let reader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            for part in parts {
                try Task.checkCancellation()
                let source = Darwin.open(part.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard source >= 0 else { throw EngineError(.missingVolume) }
                let input = FileHandle(fileDescriptor: source, closeOnDealloc: true)
                defer { try? input.close() }
                var info = stat()
                guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
                    throw EngineError(.missingVolume)
                }
                while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: bytes)
                }
            }
            try Task.checkCancellation()
            try output.close()
            return reader
        } catch {
            try? output.close()
            try? reader.close()
            throw error is CancellationError ? EngineError(.cancelled) : EngineError(error)
        }
    }

    static func recover(_ error: EngineError, name: String) -> EngineError {
        guard baseName(name) != nil else { return error }
        if error.failure == .notAnArchive { return EngineError(.missingVolume) }
        if error.failure == .failed {
            let text = error.message.lowercased()
            // A complete split archive may use an unavailable codec (#316). The generic
            // 7-Zip failure prefix is not evidence that a volume is missing in that case.
            if text.contains("unsupported method") { return error }
            if ["unexpected end", "headers error", "data error", "crc failed", "cannot find volume", "missing volume", "7-zip couldn’t finish"].contains(where: text.contains) {
                return EngineError(.missingVolume)
            }
        }
        return error
    }
}
