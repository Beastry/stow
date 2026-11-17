import Foundation
import Testing
@testable import Stow

/// #326: a batch's results can be collected in a new folder made for it.
@MainActor
struct ResultFolderTests {
    @Test func alwaysANewFolderNeverAnExistingOne() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let first = try ResultFolder.create(in: folder.url, named: "Results")
        #expect(first.lastPathComponent == "Results")
        // Something already there, a folder with content or a plain file, is skipped untouched.
        try Data("keep".utf8).write(to: first.appending(path: "mine.txt"))
        try Data("file".utf8).write(to: folder.url.appending(path: "Results 2"))
        let second = try ResultFolder.create(in: folder.url, named: "Results")
        #expect(second.lastPathComponent == "Results 3")
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
        #expect(try Data(contentsOf: first.appending(path: "mine.txt")) == Data("keep".utf8))
        #expect(try Data(contentsOf: folder.url.appending(path: "Results 2")) == Data("file".utf8))
    }

    @Test func aMissingParentIsAnError() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        #expect(throws: POSIXError.self) { try ResultFolder.create(in: folder.url.appending(path: "gone")) }
        // Every numbered name taken: an error, not an existing folder.
        try FileManager.default.createDirectory(at: folder.url.appending(path: "x"), withIntermediateDirectories: false)
        #expect(throws: POSIXError.self) { try ResultFolder.create(in: folder.url, named: "x", attempts: 1) }
    }

    @Test func onlyAnEmptyFolderIsRemoved() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let empty = try ResultFolder.create(in: folder.url, named: "Empty")
        let used = try ResultFolder.create(in: folder.url, named: "Used")
        try Data("x".utf8).write(to: used.appending(path: "a.txt"))
        #expect(ResultFolder.removeIfEmpty(empty))
        #expect(!ResultFolder.removeIfEmpty(used))
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(FileManager.default.fileExists(atPath: used.appending(path: "a.txt").path))
    }
}

@Suite("Batch results in a new folder", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled"))
@MainActor
struct BatchResultFolderTests {
    /// Archives with two files each, so each gets a folder named after it (no conflict prompts).
    private func archives(_ names: [String], in folder: URL) async throws -> [URL] {
        let sevenZip = try #require(SevenZip.bundled())
        let input = folder.appending(path: "input"), work = folder.appending(path: "work")
        for path in [input, work] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("one".utf8).write(to: input.appending(path: "one.txt"))
        try Data("two".utf8).write(to: input.appending(path: "two.txt"))
        var urls: [URL] = []
        for name in names {
            let target = folder.appending(path: "archives/\(name)")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            _ = try await sevenZip.create(CreateRequest(operationID: UUID().uuidString, archiveName: name,
                                                         format: .sevenZip, level: .store),
                                          from: input, into: target, work: work) { _ in }
            urls.append(target.appending(path: name + ".7z"))
        }
        return urls
    }

    private func run(_ queue: BatchQueue, _ urls: [URL], into folder: URL) async throws {
        var done = false
        queue.aftercare = { _, _ in done = true }
        queue.enqueue(urls, into: folder, ownsDestination: true)
        for _ in 0..<2_000 where !done { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done)
    }

    @Test func eachArchiveKeepsItsOwnFolderInside() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let urls = try await archives(["first", "last"], in: folder.url)
        let bad = folder.url.appending(path: "archives/bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        let destination = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: destination.appending(path: "notes.txt"))
        let results = try ResultFolder.create(in: destination, named: "Extracted Archives")
        let queue = BatchQueue()
        // The same archive chosen twice is extracted once.
        try await run(queue, [urls[0], bad, urls[1], urls[0]], into: results)
        #expect(queue.jobs.count == 3)
        #expect(queue.summary.completed == 2 && queue.summary.failed == 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: results.path)) == ["first", "last"])
        #expect(try Data(contentsOf: results.appending(path: "first/one.txt")) == Data("one".utf8))
        #expect(try Data(contentsOf: results.appending(path: "last/two.txt")) == Data("two".utf8))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) == ["notes.txt", "Extracted Archives"])
        #expect(try Data(contentsOf: destination.appending(path: "notes.txt")) == Data("unrelated".utf8))
    }

    /// Nothing extracted (a failure and a cancelled job): the empty folder goes, nothing else does.
    @Test func anEmptyResultFolderIsRemoved() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let urls = try await archives(["only"], in: folder.url)
        let bad = folder.url.appending(path: "archives/bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        let destination = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: destination.appending(path: "notes.txt"))
        let results = try ResultFolder.create(in: destination, named: "Extracted Archives")
        let queue = BatchQueue()
        var done = false
        queue.aftercare = { _, _ in done = true }
        queue.enqueue([bad, urls[0]], into: results, ownsDestination: true)
        if let waiting = queue.jobs.last { queue.cancel(waiting.id) }
        for _ in 0..<2_000 where !done { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.summary.failed == 1 && queue.summary.stopped == 1)
        #expect(!FileManager.default.fileExists(atPath: results.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["notes.txt"])
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
    }

    /// A folder the person chose is never removed, even when nothing lands in it.
    @Test func aChosenFolderIsNeverRemoved() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let bad = folder.url.appending(path: "bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        let chosen = folder.url.appending(path: "chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let queue = BatchQueue()
        var done = false
        queue.aftercare = { _, _ in done = true }
        queue.enqueue([bad], into: chosen)
        for _ in 0..<2_000 where !done { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: chosen.path))
    }
}
