import Foundation
import Testing
@testable import Stow

/// Run with scripts/check-icloud-output.swift. The test host receives implicit security-scoped
/// bookmarks to fresh fixture directories, just as one process can hand a file to another.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_CLOUD_FIXTURES"] != nil))
@MainActor
struct CloudPublicationTests {
    @Test func publishesToCloudLocations() async throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["STOW_CLOUD_FIXTURES"])
        let bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(encoded.utf8))
        for (name, bookmark) in bookmarks {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try #require(name.hasPrefix("Stow-Cloud-Test-") && folder.lastPathComponent == name)
            // File providers can mark a fresh bookmark stale during materialization. Verify the
            // resolved directory against the launcher's random marker before writing into it.
            let marker = try String(contentsOf: folder.appending(path: ".fixture-id"), encoding: .utf8)
            try #require(marker == name)
            try #require(FileManager.default.isUbiquitousItem(at: folder))
            try await exercise(folder)
        }
    }

    private func exercise(_ folder: URL) async throws {
        let local = try TemporaryFolder()
        defer { local.cleanUp() }
        let bytes = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        let source = local.url.appending(path: "payload.bin")
        try bytes.write(to: source)
        let items = [TreeStream.Item(source: source, path: "payload.bin")]
        let ownedExport = try TrayExport.copy(source, into: folder, ownedRoot: local.url)
        #expect(try Data(contentsOf: ownedExport) == bytes)
        for (index, format) in [PackFormat.zip, .sevenZip, .zip].enumerated() {
            let password = index == 1 ? "fixture" : nil
            let request = CreateRequest(operationID: UUID().uuidString, archiveName: "sample",
                                        format: format, level: .store, password: password,
                                        volumeSize: index == 2 ? 2048 : nil, verify: true)
            let result = try await ArchiveCreation.run(items, totalBytes: Int64(bytes.count), attributes: false,
                                                      request: request, named: "sample", in: folder) { _ in }
            #expect(result.report.verified)
            #expect(index != 2 || result.placed.count > 1)
            let first = try #require(result.placed.first)
            let before = try result.placed.map { try Data(contentsOf: $0) }
            let listing = try await ArchiveEngine.shared.list(first, password: password)
            var archive = Archive(listing: listing, url: first)
            archive.source?.password = password
            for selection in [nil, Optional(archive.files)] {
                let extracted = try await Extraction.run(archive, selection: selection, to: folder) { _ in }
                #expect(extracted.isComplete)
                let output = try #require(extracted.placed.first)
                #expect(output != ownedExport)
                #expect(try Data(contentsOf: output) == bytes)
            }
            #expect(try result.placed.map { try Data(contentsOf: $0) } == before)
            if index == 0 {
                let operations: [EditOperation] = [.rename(from: "payload.bin", to: "renamed.bin")]
                let cancelled = Task {
                    try await ArchiveSaver.save(archive: first, operations: operations, items: [], faults: .cancelDuringTransfer)
                }
                await expectEngineFailure(.cancelled) { try await cancelled.value }
                #expect(try Data(contentsOf: first) == before[0])
                let edited = try await ArchiveSaver.save(archive: first, operations: operations, items: [])
                #expect(edited.entries.map(\.path) == ["renamed.bin"])
                let back = try await Extraction.run(Archive(listing: edited, url: first), selection: nil, to: folder) { _ in }
                let renamed = try #require(back.placed.first)
                #expect(try Data(contentsOf: renamed) == bytes)
            }
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: ownedExport) == bytes)
    }
}
