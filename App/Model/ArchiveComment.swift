import Foundation

/// An archive comment as plain text to show and copy (#327). The bytes are whatever the archive's
/// author stored; they are never interpreted: no Markdown, no links, no terminal codes.
nonisolated enum ArchiveComment {
    /// Nil when nothing readable is left. Valid UTF-8 is read as UTF-8; anything else in the
    /// encoding chosen for the archive's names, or the one that reads most like text.
    static func text(from bytes: Data, encoding: NameEncoding? = nil) -> String? {
        // A zero byte ends the text for the tools that write comments; what follows is not text.
        let bytes = bytes.prefix(ZipComment.maximumLength).prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        let decoded = String(data: bytes, encoding: .utf8) ?? encoding?.decode(Data(bytes))
            ?? NameEncoding.bestReading(of: Data(bytes)).name
        let text = plain(decoded)
        return text.isEmpty ? nil : text
    }

    /// Line endings become "\n"; other control characters, and the invisible characters that
    /// reorder or hide text, go. Blank lines at either end go too.
    static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            switch scalar.value {
            case 0x0D, 0x85, 0x2028, 0x2029: scalars.append("\n")
            case 0x0A: if previous != "\r" { scalars.append("\n") }
            case 0x09: scalars.append(scalar)
            case 0..<0x20, 0x7F...0x9F: continue
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF, 0xFFF9...0xFFFB: continue
            default: scalars.append(scalar)
            }
        }
        let lines = String(scalars).split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        let kept = lines.drop { $0.allSatisfy(\.isWhitespace) }.reversed().drop { $0.allSatisfy(\.isWhitespace) }.reversed()
        return kept.joined(separator: "\n")
    }
}
