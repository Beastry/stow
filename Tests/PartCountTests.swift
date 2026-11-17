import Foundation
import Testing
@testable import Stow

/// #322: split ZIP and 7Z archives into a requested number of parts, measured from the final size.
struct PartCountTests {
    @Test func partsAreNearlyEqualAndAddUp() {
        #expect(SplitArchive.partSizes(total: 10_000, requested: 3) == [3_334, 3_333, 3_333])
        #expect(SplitArchive.partSizes(total: 9_000, requested: 3) == [3_000, 3_000, 3_000])
        for (total, count) in [(1_048_577, 7), (123_456_789, 999), (4_096, 4), (2_048, 2)] as [(Int64, Int)] {
            let sizes = SplitArchive.partSizes(total: total, requested: count)
            #expect(sizes.count == count)
            #expect(sizes.reduce(0, +) == total)
            #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) <= 1)
            #expect(sizes.allSatisfy { $0 >= SplitArchive.minimumPartBytes })
        }
    }

    /// No part under 1 KB: a small archive gets fewer parts, down to one.
    @Test func tinyArchivesGetFewerParts() {
        #expect(SplitArchive.partSizes(total: 5_000, requested: 10) == [1_250, 1_250, 1_250, 1_250])
        #expect(SplitArchive.partSizes(total: 1_500, requested: 5) == [1_500])
        #expect(SplitArchive.partSizes(total: 10, requested: 4) == [10])
        #expect(SplitArchive.partSizes(total: 0, requested: 4).isEmpty)
        #expect(SplitArchive.partCount(total: 5_000, requested: 10) == 4)
    }

    @Test func countIsClampedToNameableParts() {
        #expect(SplitArchive.partCountRange == 2...999)
        #expect(SplitArchive.partCount(total: 100_000_000, requested: 5_000) == 999)
        #expect(SplitArchive.partCount(total: 100_000_000, requested: 0) == 1)
    }

    @Test func splitWritesExactBytesAndRemovesTheWhole() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = folder.url.appending(path: "Project.zip")
        let bytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
        try bytes.write(to: archive)
        try await SplitArchive.split(archive, into: 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(names == ["Project.zip.001", "Project.zip.002", "Project.zip.003"])
        let parts = try names.map { try Data(contentsOf: folder.url.appending(path: $0)) }
        #expect(parts.map(\.count) == [3_334, 3_333, 3_333])
        #expect(parts.reduce(Data(), +) == bytes)
    }

    /// A name already taken stops the split: what it wrote goes, the archive stays whole.
    @Test func aFailedSplitLeavesTheArchiveAsItWas() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = folder.url.appending(path: "Project.7z")
        let bytes = Data(repeating: 9, count: 8_192)
        try bytes.write(to: archive)
        try Data("other".utf8).write(to: folder.url.appending(path: "Project.7z.002"))
        await #expect(throws: EngineError.self) { try await SplitArchive.split(archive, into: 4) }
        #expect(try Data(contentsOf: archive) == bytes)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "Project.7z.001").path))
        #expect(try Data(contentsOf: folder.url.appending(path: "Project.7z.002")) == Data("other".utf8))
    }

    @Test func aCancelledSplitLeavesTheArchiveAsItWas() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = folder.url.appending(path: "Big.zip")
        let bytes = Data(repeating: 1, count: 4 * 1024 * 1024)
        try bytes.write(to: archive)
        let task = Task { try await SplitArchive.split(archive, into: 4) }
        task.cancel()
        await #expect(throws: EngineError.self) { try await task.value }
        #expect(try Data(contentsOf: archive) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["Big.zip"])
    }

    @Test func optionsKeepOneWayOfSplitting() {
        var options = PackOptions()
        options.setFormat(.zip)
        options.setSplit(.mb100)
        options.setPartCount(5)
        #expect(options.partCount == 5 && options.split == .none && options.isSplit)
        #expect(options.splitPhrase == String(localized: "in 5 equal parts"))
        options.setSplit(.mb700)
        #expect(options.partCount == nil && options.split == .mb700)
        options.setPartCount(1)
        options.setPartCount(1_000)
        #expect(options.partCount == nil)
        options.setPartCount(3)
        // TAR can't: the count goes with the format, rather than being kept for a format that ignores it.
        options.setCustomFormat(.tar)
        #expect(options.partCount == nil)
        options.setFormat(.sevenZip)
        options.setPartCount(4)
        #expect(options.estimatedParts(for: 1_000_000) == 4)
        #expect(options.estimatedParts(for: 3_000) == 2)
    }

    @Test func notesSayWhatComesOut() throws {
        var options = PackOptions()
        options.setFormat(.zip)
        options.setPartCount(3)
        let even = try #require(Compatibility.partsNote(for: options, parts: 3, archiveName: "Project"))
        #expect(even.title == String(localized: "Comes out in 3 parts"))
        #expect(even.detail.contains("Project.zip.001 – .003"))
        let tiny = try #require(Compatibility.partsNote(for: options, parts: 1, archiveName: "Project"))
        #expect(tiny.title == String(localized: "Too small for 3 parts"))
    }
}

@Suite("Split by part count through 7-Zip", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled"))
@MainActor
struct PartCountEngineTests {
    @Test(arguments: [PackFormat.zip, .sevenZip], [false, true])
    func countedPartsReopenVerifyAndExtract(format: PackFormat, encrypted: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let input = folder.url.appending(path: "input"), output = folder.url.appending(path: "parts")
        let work = folder.url.appending(path: "work")
        for url in [input, output, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<40_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try bytes.write(to: input.appending(path: "payload.bin"))
        let password = encrypted ? "swordfish" : nil
        var request = CreateRequest(operationID: UUID().uuidString, archiveName: "Project", format: format,
                                    level: .store, password: password)
        request.partCount = 4
        request.verify = true
        let report = try await SevenZip.bundled()!.create(request, from: input, into: output, work: work) { _ in }
        #expect(report.verified)
        let ext = format.fileExtension
        #expect(report.files == (1...4).map { "Project.\(ext).00\($0)" })
        let sizes = try report.files.map { Int64(try Data(contentsOf: output.appending(path: $0)).count) }
        #expect(sizes.reduce(0, +) == report.size)
        #expect(sizes.max()! - sizes.min()! <= 1)
        let first = output.appending(path: report.files[0])
        let listing = try await ArchiveEngine.shared.list(first, password: password)
        #expect(listing.entries.map(\.path) == ["payload.bin"])
        let extracted = try await ArchiveEngine.shared.extract(first, paths: [], password: password) { _ in }
        defer { ArchiveEngine.shared.discard(extracted) }
        let received = folder.url.appending(path: "received")
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: false)
        try await ArchiveEngine.shared.receive(extracted, into: received)
        #expect(try Data(contentsOf: received.appending(path: "payload.bin")) == bytes)

        // Another tool: the joined parts are an ordinary archive (macOS's unzip for a plain ZIP).
        if format == .zip, !encrypted {
            let joined = folder.url.appending(path: "joined.zip")
            try sizes.indices.map { try Data(contentsOf: output.appending(path: report.files[$0])) }.reduce(Data(), +).write(to: joined)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-tq", joined.path]
            unzip.standardOutput = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0)
        }
    }

    /// A part size wins over a count, and other formats ignore the count.
    @Test func countIsIgnoredWhereItDoesNotApply() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let input = folder.url.appending(path: "input"), work = folder.url.appending(path: "work")
        for url in [input, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data(repeating: 7, count: 20_000).write(to: input.appending(path: "a.bin"))
        for format in [PackFormat.tar, .zip] {
            let output = folder.url.appending(path: "out-\(format.fileExtension)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            var request = CreateRequest(operationID: UUID().uuidString, archiveName: "P", format: format, level: .store)
            request.partCount = 3
            if format == .zip { request.volumeSize = 8_192 }
            let report = try await SevenZip.bundled()!.create(request, from: input, into: output, work: work) { _ in }
            if format == .tar {
                #expect(report.files == ["P.tar"])
            } else {
                let firstSize = Int64(try Data(contentsOf: output.appending(path: report.files[0])).count)
                #expect(report.files.count == 3 && firstSize == 8_192)
            }
        }
    }
}
