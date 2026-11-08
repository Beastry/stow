import Foundation
import Testing
import Synchronization
@testable import Stow

private final class Zstd7zFixtureLocator: NSObject {}

@Suite("Zstd-in-7Z decoding", .serialized)
@MainActor
struct Zstd7zCompatibilityTests {
    private var fixtures: URL {
        get throws {
            try #require(Bundle(for: Zstd7zFixtureLocator.self)
                .url(forResource: "Fixtures", withExtension: nil)).appending(path: "Zstd7z")
        }
    }
    private var payload: Data {
        Data(String(repeating: "Stow Zstd-in-7Z verification — 中文\n", count: 500).utf8)
    }
    private func password(for name: String) -> String? {
        name == "encrypted.7z" ? "stow-fixture-only"
            : name.hasPrefix("encrypted-split") ? "fixture-only" : nil
    }

    @Test(arguments: ["plain.7z", "encrypted.7z", "delta-zstd.7z",
                      "split-zstd.7z.001", "encrypted-split-zstd.7z.001",
                      "properties-current.7z", "properties-legacy3.7z", "frame-checksum.7z", "solid-multifile.7z", "nonsolid-multifile.7z"])
    func exactBytesThroughSandboxedVerifyPreviewAndExtraction(name: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = folder.url.appending(path: "Source")
        try FileManager.default.copyItem(at: fixtures, to: source)
        let archiveURL = source.appending(path: name)
        let originals = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == name || (name.hasSuffix(".001") && $0.lastPathComponent.hasPrefix(String(name.dropLast(3)))) }
            .map { ($0, try Data(contentsOf: $0)) })
        let password = password(for: name)
        let listing = try await ArchiveEngine.shared.list(archiveURL, password: password)
        #expect(listing.entries.contains { $0.path == "payload.txt" && $0.size == 20_000 })
        try await ArchiveEngine.shared.verify(archiveURL, password: password)
        var archive = Archive(listing: listing, url: archiveURL)
        archive.source?.password = password
        let entry = try #require(archive.entry(at: "payload.txt"))
        let cache = PreviewCache()
        let preview = try await cache.file(for: entry, in: archive, password: password)
        #expect(try Data(contentsOf: preview) == payload)
        for selected in [false, true] {
            let destination = folder.url.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            _ = try await Extraction.run(archive, selection: selected ? [entry] : nil, to: destination) { _ in }
            // Extract All places a multi-file archive in its named folder.
            let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
            let extracted = try #require(files.first { $0.hasSuffix("payload.txt") })
            #expect(try Data(contentsOf: destination.appending(path: extracted)) == payload)
            if name.hasSuffix("multifile.7z"), !selected {
                let binary = try #require(files.first { $0.hasSuffix("nested/bytes.bin") })
                #expect(try Data(contentsOf: destination.appending(path: binary)) == Data((0..<9).flatMap { _ in (0...255).map(UInt8.init) }))
                if name == "solid-multifile.7z" {
                    let empty = try #require(files.first { $0.hasSuffix("empty.txt") })
                    #expect(try Data(contentsOf: destination.appending(path: empty)).isEmpty)
                }
            }
            for (part, bytes) in originals { #expect(try Data(contentsOf: part) == bytes) }
        }
    }

    @Test(arguments: ["properties-unknown-flags.7z", "properties-unknown-length.7z",
                      "over-window.7z", "crc-mismatch.7z", "frame-checksum-mismatch.7z", "truncated-stream.7z"])
    func invalidPayloadDoesNotPublishOrChangeSource(name: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archiveURL = try fixtures.appending(path: name)
        let original = try Data(contentsOf: archiveURL)
        let listing = try await ArchiveEngine.shared.list(archiveURL)
        let archive = Archive(listing: listing, url: archiveURL)
        do {
            try await ArchiveEngine.shared.verify(archiveURL)
            Issue.record("Invalid Zstd input passed verification: \(name)")
        } catch { #expect(error.failure == .failed) }
        for selected in [false, true] {
            let destination = folder.url.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                _ = try await Extraction.run(archive, selection: selected ? archive.entries : nil, to: destination) { _ in }
                Issue.record("Invalid Zstd input was published: \(name)")
            } catch { #expect(error.failure == .failed) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(try Data(contentsOf: archiveURL) == original)
        }
    }

    @Test(arguments: ["encrypted.7z", "encrypted-split-zstd.7z.001"])
    func wrongPasswordRemainsTyped(name: String) async throws {
        let archiveURL = try fixtures.appending(path: name)
        await expectEngineFailure(.wrongPassword) {
            try await ArchiveEngine.shared.verify(archiveURL, password: "wrong-fixture-password")
        }
    }

    @Test(arguments: ["solid-multifile.7z", "nonsolid-multifile.7z"])
    func stagedSaveCanAddRenameDeleteAndPreserveUnchangedBytes(name: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archiveURL = folder.url.appending(path: name)
        try FileManager.default.copyItem(at: fixtures.appending(path: name), to: archiveURL)
        let newItem = folder.url.appending(path: "new.txt")
        try Data("new staged content".utf8).write(to: newItem)
        let operations: [EditOperation] = [.add(destinationFolder: "", items: ["new.txt"]),
                                           .rename(from: "payload.txt", to: "renamed.txt"),
                                           .delete(paths: ["nested/bytes.bin"])]
        let listing = try await ArchiveSaver.save(archive: archiveURL, operations: operations,
                                                  items: [TreeStream.Item(source: newItem, path: "new.txt")],
                                                  identity: FileIdentity(of: archiveURL))
        #expect(listing.entries.contains { $0.path == "renamed.txt" })
        #expect(!listing.entries.contains { $0.path == "payload.txt" || $0.path == "nested/bytes.bin" })
        try await ArchiveEngine.shared.verify(archiveURL)
        let archive = Archive(listing: listing, url: archiveURL)
        let cache = PreviewCache()
        let retained = try await cache.file(for: #require(archive.entry(at: "renamed.txt")), in: archive)
        #expect(try Data(contentsOf: retained) == payload)
        let added = try await cache.file(for: #require(archive.entry(at: "new.txt")), in: archive)
        #expect(try Data(contentsOf: added) == Data("new staged content".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingActiveZstdDecodeDoesNotPublish() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archiveURL = try fixtures.appending(path: "cancellation.7z")
        let archive = Archive(listing: try await ArchiveEngine.shared.list(archiveURL), url: archiveURL)
        let destination = folder.url.appending(path: "Out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let started = ZstdFractions()
        let task = Task { try await Extraction.run(archive, selection: nil, to: destination) { started.add($0) } }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(20)
        while !started.values.contains(where: { $0 > 0 && $0 < 1 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(started.values.contains(where: { $0 > 0 && $0 < 1 }), "No intermediate progress arrived from active Zstd decoder")
        task.cancel()
        await expectEngineFailure(.cancelled) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}

private nonisolated final class ZstdFractions: Sendable {
    private let storage = Mutex<[Double]>([])
    var values: [Double] { storage.withLock { $0 } }
    func add(_ value: Double) { storage.withLock { $0.append(value) } }
}
