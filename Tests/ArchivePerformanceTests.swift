import Foundation
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
        let media = Data((0..<(2 * 1024 * 1024)).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        for index in 0..<4 {
            try media.write(to: mixed.appending(path: "asset-\(index).bin"))
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
        #expect(files.count == (label == "small-zip" ? 1000 : 20))
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
        #expect(try Data(contentsOf: singleFile) == Data(contentsOf: source.appending(path: selected.name)))
        for file in files {
            let values = try allFolder.appending(path: file.name).resourceValues(forKeys: [.fileSizeKey])
            #expect(values.fileSize.map(Int64.init) == file.size)
        }

        print("STOW_BENCHMARK \(label) files=\(files.count) input_bytes=\(report.totalBytes) output_bytes=\(packedBytes)"
              + " pack_ms=\(milliseconds(packTime)) first_list_ms=\(milliseconds(firstList))"
              + " repeat_list_ms=\(milliseconds(repeatedList)) selected_ms=\(milliseconds(selectedTime))"
              + " all_ms=\(milliseconds(allTime))")
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
#endif
