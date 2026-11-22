import Darwin
import Foundation
import Synchronization
import Testing
@testable import Stow

#if STOW_ARCHIVE_BENCHMARK
@Suite("Sandboxed archive performance")
@MainActor
struct ArchivePerformanceTests {
    @Test(.timeLimit(.minutes(2)))
    func baseline() async throws {
        let scratch = try TemporaryFolder()
        defer { scratch.cleanUp() }
        let mixed = try directory("Mixed", under: scratch.url)
        let small = try directory("Small", under: scratch.url)
        var state: UInt64 = 0x329
        let randomBytes = Data((0..<(2 * 1024 * 1024)).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        for index in 0..<4 {
            try randomBytes.write(to: mixed.appending(path: "asset-\(index).bin"))
        }
        let vector = Data(String(repeating: "<path d=\"M0 0L10 10\"/>\n", count: 4096).utf8)
        for index in 0..<16 {
            try vector.write(to: mixed.appending(path: "drawing-\(index).txt"))
        }
        for index in 0..<1000 {
            try Data("record=\(index)\nname=sample\n".utf8).write(to: small.appending(path: "file-\(index).txt"))
        }

        let packed = try directory("Packed", under: scratch.url)
        try await measure("mixed-zip", source: mixed, packed: packed, scratch: scratch.url)
        try await measure("small-zip", source: small, packed: packed, scratch: scratch.url)
        try await measure("mixed-encrypted", source: mixed, packed: packed, scratch: scratch.url, password: "fixture")
        try await measure("mixed-split", source: mixed, packed: packed, scratch: scratch.url, partCount: 3)

        let bundle = Bundle(for: BenchmarkBundleToken.self)
        let corpus = try #require(bundle.resourceURL?.appending(path: "Fixtures/BenchmarkCorpus", directoryHint: .isDirectory))
        let media = corpus.appending(path: "Media", directoryHint: .isDirectory)
        let design = corpus.appending(path: "Design", directoryHint: .isDirectory)
        let apps = corpus.appending(path: "Apps", directoryHint: .isDirectory)
        try await measure("video-zip", source: media, packed: packed, scratch: scratch.url)
        try await measure("design-font-zip", source: design, packed: packed, scratch: scratch.url)
        try await measure("app-zip", source: apps, packed: packed, scratch: scratch.url)
        try await measure("media-encrypted-split", source: corpus, packed: packed, scratch: scratch.url,
                          password: "fixture", partCount: 3)
        try await measureCancellation(source: media, packed: packed)
        let trayDestination = try directory("TrayCopy", under: scratch.url)
        let trayStart = ContinuousClock.now
        let trayResult = try TrayCollection.copy([small], named: "Collection", into: trayDestination)
        let copied = trayResult.appending(path: "Small", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copied.path).count == 1_000)
        print("STOW_BENCHMARK tray-copy files=1000 elapsed_ms=\(milliseconds(trayStart.duration(to: .now)))")
        let mounted = FileManager.default.temporaryDirectory.appending(path: "StowBenchmarkVolume", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: mounted.appending(path: ".stow-benchmark-volume").path) {
            var originalDevice = stat()
            var mountedDevice = stat()
            try #require(stat(small.path, &originalDevice) == 0 && stat(mounted.path, &mountedDevice) == 0)
            try #require(originalDevice.st_dev != mountedDevice.st_dev)
            let run = try directory(UUID().uuidString, under: mounted)
            defer { try? FileManager.default.removeItem(at: run) }
            let copyStart = ContinuousClock.now
            let copied = try TrayCollection.copy([small], named: "Collection", into: run)
            let copyTime = copyStart.duration(to: .now)
            #expect(try FileManager.default.contentsOfDirectory(atPath: copied.appending(path: "Small").path).count == 1_000)
            print("STOW_BENCHMARK cross-volume-tray-copy files=1000 elapsed_ms=\(milliseconds(copyTime))")
            try await measure("cross-volume-small-zip", source: small, packed: run, scratch: run)
        }


    }

    private func measure(_ label: String, source: URL, packed: URL, scratch: URL,
                         password: String? = nil, partCount: Int? = nil) async throws {
        let clock = ContinuousClock()
        let packStart = clock.now
        var options = PackOptions()
        options.setFormat(.zip)
        let request = await PackRequest.gather([source])
        let report = Compatibility.report(for: request.files, options: options, password: password ?? "")
        var create = CreateRequest(operationID: UUID().uuidString, archiveName: label, format: .zip,
                                   password: password, volumeSize: nil, threads: 1)
        create.partCount = partCount
        let result = try await ArchiveCreation.run(report.items, totalBytes: report.totalBytes, attributes: false,
                                                   request: create, named: label, in: packed) { _ in }
        let packTime = packStart.duration(to: clock.now)
        #expect(result.placed.count == (partCount ?? 1))
        let url = try #require(result.placed.first)
        let packedBytes = try result.placed.reduce(0) { bytes, part in
            bytes + (try part.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }

        let initialStart = clock.now
        _ = try await ArchiveEngine.shared.list(url, password: password)
        let firstList = initialStart.duration(to: clock.now)
        let repeatStart = clock.now
        let listing = try await ArchiveEngine.shared.list(url, password: password)
        let repeatedList = repeatStart.duration(to: clock.now)
        var archive = Archive(listing: listing, url: url)
        archive.source?.password = password
        let files = archive.entries.filter { !$0.isFolder }.sorted { $0.path < $1.path }
        let expected = Dictionary(uniqueKeysWithValues: report.included.filter { !$0.isFolder }
            .compactMap { file in file.source.map { (file.path, $0) } })
        #expect(files.count == expected.count)
        let selected = try #require(files.first)
        let selectedDirectory = try directory(label + "-selected", under: scratch)
        let allDirectory = try directory(label + "-all", under: scratch)

        let selectedStart = clock.now
        let single = try await Extraction.run(archive, selection: [selected], to: selectedDirectory) { _ in }
        let selectedTime = selectedStart.duration(to: clock.now)
        let allStart = clock.now
        let all = try await Extraction.run(archive, selection: nil, to: allDirectory) { _ in }
        let allTime = allStart.duration(to: clock.now)
        let singleFile = try #require(single.placed.first)
        let allFolder = try #require(all.placed.first)
        let original = try #require(expected[selected.path])
        #expect(try Data(contentsOf: singleFile) == Data(contentsOf: original))
        for file in files {
            let relative = String(file.path.dropFirst(source.lastPathComponent.count + 1))
            let result = allFolder.appending(path: relative)
            let original = try #require(expected[file.path])
            #expect(FileManager.default.contentsEqual(atPath: result.path, andPath: original.path))
        }

        print("STOW_BENCHMARK \(label) files=\(files.count) input_bytes=\(report.totalBytes) output_bytes=\(packedBytes)"
              + " pack_ms=\(milliseconds(packTime)) first_list_ms=\(milliseconds(firstList))"
              + " repeat_list_ms=\(milliseconds(repeatedList)) selected_ms=\(milliseconds(selectedTime))"
              + " all_ms=\(milliseconds(allTime))")
    }

    private func measureCancellation(source: URL, packed: URL) async throws {
        let gathered = await PackRequest.gather([source])
        let report = Compatibility.report(for: gathered.files, options: PackOptions())
        let name = "cancelled-video"
        let request = CreateRequest(operationID: UUID().uuidString, archiveName: name,
                                    format: .zip, threads: 1)
        let activity = Mutex(false)
        let packing = Task {
            try await ArchiveCreation.run(report.items, totalBytes: report.totalBytes, attributes: false,
                                          request: request, named: name, in: packed) { progress in
                if progress > 0 { activity.withLock { $0 = true } }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !activity.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancellationStart = ContinuousClock.now
        packing.cancel()
        switch await packing.result {
        case .success: Issue.record("Pack completed before cancellation")
        case .failure(let error): #expect(EngineError(error).failure == .cancelled)
        }
        #expect(!FileManager.default.fileExists(atPath: packed.appending(path: name + ".zip").path))
        print("STOW_BENCHMARK cancel-pack elapsed_ms=\(milliseconds(cancellationStart.duration(to: .now)))")
    }

    private func directory(_ name: String, under root: URL) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func milliseconds(_ elapsed: Duration) -> Int64 {
        elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }
}
private final class BenchmarkBundleToken {}

#endif
