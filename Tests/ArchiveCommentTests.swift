import Foundation
import Synchronization
import Testing
@testable import Stow

/// #327: a ZIP's archive comment is read from the file, decoded as text and shown as plain text.
struct ArchiveCommentTests {
    /// An end-of-central-directory record for an empty archive, with `comment` after it.
    nonisolated static func record(comment: [UInt8], declared: Int? = nil, directorySize: UInt32 = 0, directoryOffset: UInt32 = 0) -> Data {
        var bytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0]
        for value in [directorySize, directoryOffset] { bytes += (0..<4).map { UInt8(value >> (8 * UInt32($0)) & 0xFF) } }
        let length = declared ?? comment.count
        bytes += [UInt8(length & 0xFF), UInt8(length >> 8)]
        return Data(bytes + comment)
    }

    @Test func readsTheBytesAfterTheRecord() {
        #expect(ZipComment.comment(inEndOf: Self.record(comment: Array("hello".utf8))) == Data("hello".utf8))
        #expect(ZipComment.comment(inEndOf: Data([1, 2, 3]) + Self.record(comment: [0xC4, 0xE3])) == Data([0xC4, 0xE3]))
    }

    @Test func noCommentIsNil() {
        #expect(ZipComment.comment(inEndOf: Self.record(comment: [])) == nil)
        #expect(ZipComment.comment(inEndOf: Data()) == nil)
        #expect(ZipComment.comment(inEndOf: Data(repeating: 0, count: 64)) == nil)
    }

    /// A length that doesn't reach the file's end, or runs past it, isn't this archive's record.
    @Test func malformedLengthsAreRefused() {
        #expect(ZipComment.comment(inEndOf: Self.record(comment: Array("hello".utf8), declared: 3)) == nil)
        #expect(ZipComment.comment(inEndOf: Self.record(comment: Array("hello".utf8), declared: 500)) == nil)
        #expect(ZipComment.comment(inEndOf: Self.record(comment: Array("hello".utf8)).dropLast(1)) == nil)
    }

    /// A central directory that would lie past the record makes it something else's bytes.
    @Test func directoryMustComeBeforeTheRecord() {
        #expect(ZipComment.comment(inEndOf: Self.record(comment: [65], directorySize: 40, directoryOffset: 10)) == nil)
        let prefix = Data(repeating: 0, count: 50)
        #expect(ZipComment.comment(inEndOf: prefix + Self.record(comment: [65], directorySize: 40, directoryOffset: 10)) == Data([65]))
        #expect(ZipComment.comment(inEndOf: Self.record(comment: [65], directorySize: 40, directoryOffset: 10), windowOffset: 1_000) == Data([65]))
        // ZIP64 placeholders say nothing about where the directory is.
        #expect(ZipComment.comment(inEndOf: Self.record(comment: [65], directorySize: 0xFFFF_FFFF, directoryOffset: 0xFFFF_FFFF)) == Data([65]))
    }

    /// A comment that contains a record of its own: the whole comment is found when the real
    /// record's length reaches the end, whichever the search meets first.
    @Test func commentContainingARecord() throws {
        let inner = Self.record(comment: Array("inner".utf8))
        let outer = Self.record(comment: Array("outer ".utf8) + [UInt8](inner))
        let found = try #require(ZipComment.comment(inEndOf: outer))
        #expect(found == Data("inner".utf8) || found == Data("outer ".utf8) + inner)
    }

    @Test func longestCommentIsReadWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stow-comment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let comment = [UInt8](repeating: 0x61, count: ZipComment.maximumLength)
        let file = folder.appending(path: "x.zip")
        try (Data(repeating: 7, count: 300) + Self.record(comment: comment, directorySize: 100, directoryOffset: 200) + Data("tail".utf8)).write(to: file)
        #expect(ZipComment.read(atPath: file.path, tailSize: 4) == Data(comment))
        #expect(ZipComment.read(atPath: file.path) == nil)
        #expect(ZipComment.read(atPath: file.path, tailSize: 1 << 40) == nil)
        #expect(ZipComment.read(atPath: folder.appending(path: "missing.zip").path) == nil)
    }

    @Test func decodesUTF8ThenTheChosenOrLikeliestEncoding() throws {
        #expect(ArchiveComment.text(from: Data("Bonjour, 你好".utf8)) == "Bonjour, 你好")
        let gbk = try #require("压缩包的说明文件".data(using: NameEncoding.named("gbk")!.encoding))
        #expect(ArchiveComment.text(from: gbk) == "压缩包的说明文件")
        let sjis = try #require("写真の説明".data(using: NameEncoding.named("sjis")!.encoding))
        #expect(ArchiveComment.text(from: sjis, encoding: NameEncoding.named("sjis")) == "写真の説明")
        // Bytes no encoding reads cleanly still come back as some text, never a crash.
        #expect(ArchiveComment.text(from: Data([0xFF, 0xFE, 0x41, 0x80, 0x81])) != nil)
    }

    @Test func emptyAndBlankCommentsShowNothing() {
        #expect(ArchiveComment.text(from: Data()) == nil)
        #expect(ArchiveComment.text(from: Data(" \r\n\t\n".utf8)) == nil)
        #expect(ArchiveComment.text(from: Data([0, 0x41, 0x42])) == nil)
    }

    @Test func textIsPlain() {
        #expect(ArchiveComment.text(from: Data("one\r\ntwo\rthree\n\n\nfour  \n\n".utf8)) == "one\ntwo\nthree\n\n\nfour")
        // Terminal codes, a right-to-left override and a zero byte: none survives, the words do.
        #expect(ArchiveComment.text(from: Data("\u{1B}[31mred\u{07} \u{202E}txt.exe".utf8)) == "[31mred txt.exe")
        #expect(ArchiveComment.text(from: Data("kept\u{0}dropped".utf8)) == "kept")
        #expect(ArchiveComment.text(from: Data("\tindented [link](https://example.com) **bold**".utf8))
                == "\tindented [link](https://example.com) **bold**")
    }

    @Test func listingCarriesTheCommentOverTheWire() throws {
        let listing = ArchiveListing(type: "zip", entries: [], comment: Data([0xC4, 0xE3, 0x0A]))
        let decoded = try JSONDecoder.engine.decode(ArchiveListing.self, from: JSONEncoder.engine.encode(listing))
        #expect(decoded.comment == Data([0xC4, 0xE3, 0x0A]))
        // A listing from before the field existed still reads.
        let old = Data(#"{"version":5,"type":"zip","entries":[]}"#.utf8)
        #expect(try JSONDecoder.engine.decode(ArchiveListing.self, from: old).comment == nil)
    }
}

@Suite("ZIP comment through 7-Zip", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled — run scripts/fetch-7zip.sh"))
struct ArchiveCommentEngineTests {
    private func zip(comment: Data?, tail: Data = Data()) throws -> (folder: URL, archive: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stow-comment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appending(path: "real.txt"))
        let archive = folder.appending(path: "x.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-X", "x.zip", "real.txt"]
        try zip.run()
        zip.waitUntilExit()
        var bytes = try Data(contentsOf: archive)
        if let comment {
            bytes.replaceSubrange((bytes.count - 2)..., with: [UInt8(comment.count & 0xFF), UInt8(comment.count >> 8)])
            bytes.append(comment)
        }
        try (bytes + tail).write(to: archive)
        return (folder, archive)
    }

    @Test func commentReachesTheArchiveUnchangedOnDisk() async throws {
        let comment = Data("Shipped by the studio.\r\nSecond line: 你好\n".utf8)
        let (folder, archive) = try zip(comment: comment)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: archive)
        let listing = try await SevenZip.bundled()!.list(.file(archive))
        #expect(listing.comment == comment)
        #expect(Archive(listing: listing, url: archive).comment == "Shipped by the studio.\nSecond line: 你好")
        #expect(try Data(contentsOf: archive) == before)
    }

    @Test func legacyEncodedCommentFollowsTheNamesEncoding() async throws {
        let big5 = try #require(NameEncoding.named("big5"))
        let comment = try #require("壓縮檔說明".data(using: big5.encoding))
        let (folder, archive) = try zip(comment: comment)
        defer { try? FileManager.default.removeItem(at: folder) }
        let listing = try await SevenZip.bundled()!.list(.file(archive))
        #expect(listing.comment == comment)
        #expect(Archive(listing: listing, url: archive, nameEncoding: big5).comment == "壓縮檔說明")
    }

    @Test func noCommentAndOtherFormatsHaveNone() async throws {
        let (folder, archive) = try zip(comment: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let listing = try await SevenZip.bundled()!.list(.file(archive))
        #expect(listing.comment == nil)
        #expect(Archive(listing: listing, url: archive).comment == nil)
    }
}
