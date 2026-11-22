import Foundation
import Synchronization
import Testing
@testable import Stow

#if STOW_CLOUD_OUTPUT
/// Run with scripts/check-icloud-output.swift. The test host receives implicit security-scoped
/// bookmarks to fresh fixture directories, just as one process can hand a file to another.
@Suite
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
            if ProcessInfo.processInfo.environment["STOW_CLOUD_TRANSITIONS"] == "1" {
                do { try await exerciseProviderTransitions(folder) }
                catch { Issue.record("Provider transition at \(folder.deletingLastPathComponent().lastPathComponent): \(error)") }
                continue
            }
            try await exercise(folder)
            try await packThroughResolvedAlias(in: folder)
            for recreate in [false, true] {
                try await expectPackToRejectMovedDestination(in: folder, recreate: recreate)
            }
        }
    }

    private func exerciseProviderTransitions(_ folder: URL) async throws {
        let local = try TemporaryFolder()
        defer { local.cleanUp() }
        let bytes = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let source = local.url.appending(path: "source.bin")
        try bytes.write(to: source)
        let request = CreateRequest(operationID: UUID().uuidString, archiveName: "provider",
                                    format: .zip, level: .store, verify: true)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ArchiveCreation.run([.init(source: source, path: "source.bin")],
                                                    totalBytes: Int64(bytes.count), attributes: false,
                                                    request: request, named: "provider", in: folder) { _ in }
        let published = try #require(result.placed.first)
        let reference = local.url.appending(path: "reference.zip")
        try FileManager.default.copyItem(at: published, to: reference)
        defer { try? FileManager.default.removeItem(at: published) }
        let referenceBytes = try Data(contentsOf: reference)
        let location = folder.deletingLastPathComponent().lastPathComponent
        print("iCloud \(location) published \(start.duration(to: clock.now)); \(referenceBytes.count) bytes")

        try await waitForProvider("upload", at: published) { url in
            let values = try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            if let error = values.ubiquitousItemUploadingError { throw error }
            return values.ubiquitousItemIsUploaded == true
        }
        print("iCloud \(location) reported uploaded \(start.duration(to: clock.now))")
        try FileManager.default.evictUbiquitousItem(at: published)
        try await waitForProvider("eviction", at: published) { CloudPlaceholder.state(of: $0) == .placeholder }
        print("iCloud \(location) reported placeholder \(start.duration(to: clock.now))")

        // Cancel Stow's wait once the live probe initiates a download. The provider may keep downloading.
        let opened = Task { @MainActor in
            var cancel = false
            try await CloudPlaceholder.waitForDownload(published, isCancelled: { cancel }) { _ in cancel = true }
        }
        await expectEngineFailure(.cancelled) { try await opened.value }
        try await waitForProvider("redownload", at: published) { url in
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if let error = values.ubiquitousItemDownloadingError { throw error }
            return values.ubiquitousItemDownloadingStatus == .current && CloudPlaceholder.state(of: url) == .local
        }
        defer { DownloadPercent.shared.stop() }
        #expect(try Data(contentsOf: published) == referenceBytes)
        let listing = try await ArchiveEngine.shared.list(published)
        let reopened = Archive(listing: listing, url: published)
        let extracted = try await Extraction.run(reopened, selection: nil, to: local.url) { _ in }
        #expect(extracted.isComplete)
        let materialized = try #require(extracted.placed.first)
        #expect(try Data(contentsOf: materialized) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        try FileManager.default.removeItem(at: published)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [".fixture-id"])
        print("iCloud \(location) redownloaded, compared bytes and cleaned up \(start.duration(to: clock.now))")
    }

    private func waitForProvider(_ phase: String, at url: URL, until ready: (URL) throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            // A fresh URL avoids reading Foundation's cached resource values from an earlier phase.
            if try ready(URL(filePath: url.path)) { return }
            guard clock.now < deadline else {
                throw NSError(domain: "StowCloudTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "iCloud did not report \(phase) within 30 seconds"])
            }
            try await Task.sleep(for: .milliseconds(250))
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

#endif

@Suite @MainActor
struct PackDestinationMutationTests {
    @Test func publishesThroughResolvedAlias() async throws {
        let local = try TemporaryFolder()
        defer { local.cleanUp() }
        try await packThroughResolvedAlias(in: local.url)
    }

    @Test(arguments: [false, true])
    func refusesMovedDestination(recreate: Bool) async throws {
        let local = try TemporaryFolder()
        defer { local.cleanUp() }
        try await expectPackToRejectMovedDestination(in: local.url, recreate: recreate)
    }
}

@MainActor
private func expectPackToRejectMovedDestination(in root: URL, recreate: Bool) async throws {
    let fixture = root.appending(path: "pack-" + UUID().uuidString, directoryHint: .isDirectory)
    let destination = fixture.appending(path: "Selected", directoryHint: .isDirectory)
    let moved = fixture.appending(path: "Moved", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    var hidden = destination.appending(path: "existing")
    let bytes = Data(repeating: 42, count: 8192)
    try bytes.write(to: hidden)
    var values = URLResourceValues()
    values.isHidden = true
    try hidden.setResourceValues(values)
    let local = try TemporaryFolder()
    defer { local.cleanUp() }
    let source = local.url.appending(path: "payload.bin")
    try bytes.write(to: source)
    let items = [TreeStream.Item(source: source, path: "payload.bin")]
    let mutation = Mutex<Result<Void, any Error>?>(nil)
    let request = CreateRequest(operationID: UUID().uuidString, archiveName: "sample",
                                format: .zip, level: .store, verify: true)
    do {
        _ = try await ArchiveCreation.run(items, totalBytes: Int64(bytes.count), attributes: false,
                                          request: request, named: "sample", in: destination) { progress in
            guard progress > 0, progress < 1 else { return }
            mutation.withLock { result in
                guard result == nil else { return }
                result = Result {
                    try FileManager.default.moveItem(at: destination, to: moved)
                    if recreate {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                        try Data("foreign".utf8).write(to: destination.appending(path: "sample.zip"))
                    }
                }
            }
        }
        Issue.record("Pack published after its selected folder moved.")
    } catch {
        #expect(error.failure == .failed)
        #expect(error.message == String(localized: "The destination folder moved or was replaced. Choose it again."))
    }
    try #require(mutation.withLock { $0 }).get()
    let movedHidden = moved.appending(path: "existing")
    #expect(try Data(contentsOf: movedHidden) == bytes)
    #expect(try movedHidden.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["existing"])
    if recreate {
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["sample.zip"])
        #expect(try Data(contentsOf: destination.appending(path: "sample.zip")) == Data("foreign".utf8))
    } else {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    #expect(try Data(contentsOf: source) == bytes)
}

@MainActor
private func packThroughResolvedAlias(in root: URL) async throws {
    let fixture = root.appending(path: "alias-" + UUID().uuidString, directoryHint: .isDirectory)
    let target = fixture.appending(path: "Target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    let alias = fixture.appending(path: "Pack Destination")
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile)
    try URL.writeBookmarkData(bookmark, to: alias)
    let aliasBefore = try Data(contentsOf: alias)
    let destination = try URL(resolvingAliasFileAt: alias, options: [.withoutUI])
    #expect(destination.standardizedFileURL == target.standardizedFileURL)

    let local = try TemporaryFolder()
    defer { local.cleanUp() }
    let data = Data("source".utf8)
    let source = local.url.appending(path: "source.txt")
    try data.write(to: source)
    let request = CreateRequest(operationID: UUID().uuidString, archiveName: "alias",
                                format: .zip, level: .store, verify: true)
    let result = try await ArchiveCreation.run([.init(source: source, path: "source.txt")],
                                                totalBytes: Int64(data.count), attributes: false,
                                                request: request, named: "alias", in: destination) { _ in }
    #expect(result.report.verified)
    #expect(result.placed.map(\.lastPathComponent) == ["alias.zip"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["alias.zip"])
    #expect(try Data(contentsOf: alias) == aliasBefore)
    #expect(try Data(contentsOf: source) == data)
}
