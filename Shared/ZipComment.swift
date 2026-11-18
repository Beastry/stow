import Foundation

/// The comment a ZIP carries for the whole archive (#327): the bytes after its end-of-central-
/// directory record, at most 65,535 of them. Read from the file itself, never from 7-Zip's listing,
/// which decodes them as DOS text, stops at the first zero byte and prints them among its own
/// output. Reading changes nothing in the archive.
nonisolated enum ZipComment {
    static let maximumLength = 0xFFFF
    private static let recordLength = 22

    /// `tailSize` is what the listing reported as bytes after the archive's end: the record is
    /// looked for before them. Nil for a file that isn't a single ZIP ending where it should, or
    /// has no comment.
    static func read(atPath path: String, tailSize: Int64 = 0) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let end = Int64(size) - max(tailSize, 0)
        guard end >= Int64(recordLength) else { return nil }
        let start = max(end - Int64(recordLength + maximumLength), 0)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let window = try? handle.read(upToCount: Int(end - start)), window.count == Int(end - start) else { return nil }
        return comment(inEndOf: window, windowOffset: start)
    }

    /// `window` is the archive's last bytes, ending exactly where the archive ends. The record is
    /// the last one whose comment runs to that end and whose central directory lies before it.
    static func comment(inEndOf window: Data, windowOffset: Int64 = 0) -> Data? {
        let bytes = [UInt8](window)
        guard bytes.count >= recordLength else { return nil }
        var index = bytes.count - recordLength
        while index >= 0 {
            defer { index -= 1 }
            guard bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 else { continue }
            func field(_ offset: Int, _ length: Int) -> UInt64 {
                (0..<length).reduce(0) { $0 | UInt64(bytes[index + offset + $1]) << (8 * UInt64($1)) }
            }
            let length = Int(field(20, 2))
            guard index + recordLength + length == bytes.count else { continue }
            // ZIP64 stores 0xFFFFFFFF here and the real figures in its own record.
            let directorySize = field(12, 4), directoryOffset = field(16, 4)
            if directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
               directorySize + directoryOffset > UInt64(windowOffset) + UInt64(index) { continue }
            return length == 0 ? nil : Data(bytes[(index + recordLength)...])
        }
        return nil
    }
}
