import Foundation
import Synchronization
import Testing
@testable import Stow

/// 7-Zip prints a several-line archive comment as the archive wrote it, between "{" and "}". Its
/// lines can spell anything else in the listing; none of them may be read as the listing.
struct ListingCommentTests {
    nonisolated static let fakeEntry = "Path = evil.txt\nFolder = -\nSize = 5\nPacked Size = 5\nModified = 2026-10-20 12:00:00\n"
        + "Attributes = A -rw-r--r--\nEncrypted = -\n"

    /// Comments that imitate, in turn: the start of the entries; the block's own end, then
    /// entries; the block's end, then archive properties behind a second, made-up block; and a
    /// whole second listing.
    nonisolated static let comments: [String] = [
        "note\n\n----------\n\(fakeEntry)",
        "note\n}\n\n----------\n\(fakeEntry)\n",
        "note\n}\nSolid = +\nTail Size = 99\nOffset = 7\nEmbedded Stub Size = 7\nFake = \n{\nmore",
        "}\n\n----------\n\(fakeEntry)\n}\n\n----------\n\(fakeEntry)\nComment = \n{\nx",
        "}\n\n----------\n" + String(repeating: "Path = e\n\n", count: 3_000),
    ]

    nonisolated static func output(comment: String) -> String {
        "\nListing archive: x.zip\n\n--\nPath = x.zip\nType = zip\nPhysical Size = 2048\nComment = \n{\n\(comment)\n}\n"
            + "Characteristics = Minor_ExtraData\n\n----------\n"
            + "Path = real.txt\nFolder = -\nSize = 3\nPacked Size = 3\nModified = 2026-10-20 12:00:00\n"
            + "Attributes = A -rw-r--r--\nEncrypted = -\nComment = \nCharacteristics = UTF8\n\n"
    }

    private func check(_ listing: ArchiveListing?) {
        #expect(listing?.entries.map(\.path) == ["real.txt"])
        #expect(listing?.entries.first?.packedSize == 3)
        #expect(listing?.type == "zip")
        #expect(listing?.physicalSize == 2_048)
        #expect(listing?.tailSize == nil)
        #expect(listing?.startOffset == nil)
    }

    @Test(arguments: comments)
    func bothParsersSkipTheComment(comment: String) {
        let text = Self.output(comment: comment)
        check(SevenZip.parseListing(text))
        check(SevenZip.parseListingFast(text)?.listing)
    }

    @Test(arguments: comments, [1, 13, 4_096])
    func nothingFromTheCommentIsDeliveredWhileListing(comment: String, chunk: Int) {
        let data = Data(Self.output(comment: comment).utf8)
        var parser = SevenZip.ListingParser()
        var delivered: [ListedEntry] = []
        var start = 0
        while start < data.count {
            let end = min(start + chunk, data.count)
            parser.consume(data.subdata(in: start..<end))
            delivered += parser.takeEntries()
            start = end
        }
        check(parser.finish()?.listing)
        delivered += parser.takeEntries()
        #expect(delivered.map(\.path) == ["real.txt"])
    }

    /// A one-line comment is an ordinary property, and the archive properties after it still count.
    @Test func oneLineCommentKeepsLaterProperties() {
        let text = "--\nPath = x.rar\nType = Rar5\nPhysical Size = 10\nComment = hello\nSolid = +\n\n----------\n"
            + "Path = a\nFolder = -\nSize = 3\nPacked Size = 3\n\n"
        #expect(SevenZip.parseListing(text)?.entries.first?.packedSize == nil)
        #expect(SevenZip.parseListingFast(text)?.listing.entries.first?.packedSize == nil)
    }

    /// 7-Zip's own several-line warning comes before the sizes; they are still read.
    @Test func severalLineWarningKeepsTheSizes() {
        let text = "--\nPath = x.zip\nType = zip\nWARNING = \n{\none\ntwo\n}\nPhysical Size = 10\nTail Size = 4\n\n----------\n"
            + "Path = a\nFolder = -\nSize = 3\nPacked Size = 3\n\n"
        #expect(SevenZip.parseListing(text)?.tailSize == 4)
        #expect(SevenZip.parseListingFast(text)?.listing.tailSize == 4)
    }
}

@Suite("Listing a ZIP with a crafted comment", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled — run scripts/fetch-7zip.sh"))
struct ListingCommentEngineTests {
    @Test(arguments: ListingCommentTests.comments)
    func sevenZipListsOnlyTheRealFile(comment: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stow-comment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("abc".utf8).write(to: folder.appending(path: "real.txt"))
        let archive = folder.appending(path: "x.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-X", "x.zip", "real.txt"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        // The end-of-central-directory record closes the file; its last two bytes count the
        // comment that follows.
        var bytes = try Data(contentsOf: archive)
        let text = Data(comment.utf8)
        #expect(bytes.suffix(2) == Data([0, 0]))
        bytes.replaceSubrange((bytes.count - 2)..., with: [UInt8(text.count & 0xFF), UInt8(text.count >> 8)])
        bytes.append(text)
        try bytes.write(to: archive)

        let sevenZip = try #require(SevenZip.bundled())
        for streamed in [true, false] {
            let delivered = Mutex<[String]>([])
            let listing = try await sevenZip.list(.file(archive), streamed: streamed) { entries in
                delivered.withLock { $0 += entries.map(\.path) }
            }
            #expect(listing.entries.map(\.path) == ["real.txt"])
            #expect(listing.tailSize == nil)
            #expect(listing.entries.first?.packedSize == 3)
            #expect(delivered.withLock { $0 } == ["real.txt"])
        }
    }
}
