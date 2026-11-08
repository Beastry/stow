import Foundation
import Synchronization
import Testing
@testable import Stow

/// Caller transactions must preserve their contracts when publication copies instead of renaming.
@Suite("Publication caller integration", .serialized)
@MainActor
struct PublicationIntegrationTests {
    private func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ root: URL, _ name: String, _ bytes: Data) throws -> URL {
        let url = root.appending(path: name)
        try bytes.write(to: url)
        return url
    }

    @Test(arguments: [Placement.Resolution.keepBoth, .merge, .skip, .replace])
    func placementConflictPolicySurvivesCopyFallback(resolution: Placement.Resolution) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let existing = try directory(destination, "Group")
        let incomingBytes = Data("incoming".utf8), existingBytes = Data("existing".utf8)
        let incoming = try file(source, "new.txt", incomingBytes)
        _ = try file(existing, "old.txt", existingBytes)

        let result = try await Placement.place([(source, "Group")], in: destination,
                                               resolve: { _ in resolution },
                                               publicationOptions: .init(forceCopy: true))
        #expect(try Data(contentsOf: incoming) == incomingBytes)
        switch resolution {
        case .keepBoth:
            #expect(result.usedCopyFallback)
            #expect(result.placed.map(\.lastPathComponent) == ["Group 2"])
            #expect(try Data(contentsOf: destination.appending(path: "Group 2/new.txt")) == incomingBytes)
            #expect(try Data(contentsOf: existing.appending(path: "old.txt")) == existingBytes)
        case .merge:
            #expect(result.usedCopyFallback && result.merged == 1)
            #expect(result.placed == [existing])
            #expect(try Data(contentsOf: existing.appending(path: "new.txt")) == incomingBytes)
            #expect(try Data(contentsOf: existing.appending(path: "old.txt")) == existingBytes)
        case .skip:
            #expect(result.skipped == 1 && result.placed.isEmpty && result.added.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["old.txt"])
            #expect(try Data(contentsOf: existing.appending(path: "old.txt")) == existingBytes)
        case .replace:
            #expect(result.usedCopyFallback && result.replaced == 1)
            #expect(result.placed == [existing])
            #expect(try Data(contentsOf: existing.appending(path: "new.txt")) == incomingBytes)
            #expect(!FileManager.default.fileExists(atPath: existing.appending(path: "old.txt").path))
        }
    }

    @Test func cancelledPlacementRollsBackEarlierPublishedItemAndKeepsSources() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let small = Data("first".utf8), large = Data(repeating: 73, count: 3_000_000)
        let first = try file(source, "first.bin", small)
        let second = try file(source, "second.bin", large)
        let observation = Mutex((chunks: 0, sawPriorOutput: false))
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            let stop = observation.withLock { value in
                value.chunks += 1
                if value.chunks == 2 {
                    value.sawPriorOutput = FileManager.default.fileExists(atPath: destination.appending(path: "first.bin").path)
                    return true
                }
                return false
            }
            if stop { throw CancellationError() }
        })
        do {
            _ = try await Placement.place([(first, "first.bin"), (second, "second.bin")], in: destination,
                                           publicationOptions: options)
            Issue.record("Expected cancellation during the second publication")
        } catch { #expect(error.failure == .cancelled) }
        #expect(observation.withLock { $0.sawPriorOutput })
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: first) == small)
        #expect(try Data(contentsOf: second) == large)
    }

    @Test func cancelledCopyReplacementRestoresOriginalBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let incomingBytes = Data(repeating: 61, count: 3_000_000)
        let originalBytes = Data("old destination bytes".utf8)
        let incoming = try file(source, "incoming.bin", incomingBytes)
        let original = try file(destination, "result.bin", originalBytes)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            chunks.withLock { $0 += 1 }
            throw CancellationError()
        })
        do {
            _ = try await Placement.place([(incoming, "result.bin")], in: destination,
                                           resolve: { _ in .replace }, publicationOptions: options)
            Issue.record("Expected cancellation while replacing the destination")
        } catch { #expect(error.failure == .cancelled) }
        #expect(chunks.withLock { $0 } == 1)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try Data(contentsOf: incoming) == incomingBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["result.bin"])
    }

    @Test(arguments: [false, true])
    func cancellationReportsModifiedEarlierOutputInsteadOfRemovingIt(modifyCurrentOutput: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let firstBytes = Data("first source".utf8), secondBytes = Data(repeating: 19, count: 3_000_000)
        let first = try file(source, "first.bin", firstBytes), second = try file(source, "second.bin", secondBytes)
        let retained = destination.appending(path: "first.bin")
        let changedBytes = Data("another writer changed the published file".utf8)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            let stop = chunks.withLock { value in value += 1; return value == 2 }
            if stop {
                try changedBytes.write(to: retained, options: .atomic)
                if modifyCurrentOutput {
                    try changedBytes.write(to: destination.appending(path: "second.bin"), options: .atomic)
                }
                throw CancellationError()
            }
        })
        do {
            _ = try await Placement.place([(first, "first.bin"), (second, "second.bin")], in: destination,
                                           publicationOptions: options)
            Issue.record("Expected retained-output recovery after cancellation")
        } catch {
            #expect(error.failure == .failed)
            #expect(error.message.contains(retained.path))
            if modifyCurrentOutput { #expect(error.message.contains(destination.appending(path: "second.bin").path)) }
        }
        #expect(chunks.withLock { $0 } == 2)
        #expect(try Data(contentsOf: retained) == changedBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == (modifyCurrentOutput ? ["first.bin", "second.bin"] : ["first.bin"]))
        if modifyCurrentOutput { #expect(try Data(contentsOf: destination.appending(path: "second.bin")) == changedBytes) }
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
    }

    @Test func splitCreationCollisionNumbersEveryPartAndPreservesExistingOutput() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let firstBytes = Data("part one".utf8), secondBytes = Data("part two".utf8)
        let first = try file(source, "first", firstBytes), second = try file(source, "second", secondBytes)
        let collision = try file(destination, "Archive.zip.002", Data("existing".utf8))
        let placed = try await ArchiveCreation.place([(first, ".zip.001"), (second, ".zip.002")],
                                                     named: "Archive", format: .zip, in: destination,
                                                     conflict: .keepBoth, publicationOptions: .init(forceCopy: true))
        #expect(placed.map(\.lastPathComponent) == ["Archive 2.zip.001", "Archive 2.zip.002"])
        #expect(try Data(contentsOf: placed[0]) == firstBytes)
        #expect(try Data(contentsOf: placed[1]) == secondBytes)
        #expect(try Data(contentsOf: collision) == Data("existing".utf8))
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "Archive.zip.001").path))
    }

    @Test(arguments: [false, true])
    func splitCreationFailureOrCancellationRollsBackEarlierPart(cancel: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let firstBytes = Data("first".utf8), secondBytes = Data(repeating: 29, count: 3_000_000)
        let first = try file(source, "first", firstBytes)
        let second = cancel ? try file(source, "second", secondBytes) : source.appending(path: "missing")
        let observation = Mutex((chunks: 0, sawPriorOutput: false))
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            let stop = observation.withLock { value in
                value.chunks += 1
                if value.chunks == 2 {
                    value.sawPriorOutput = FileManager.default.fileExists(atPath: destination.appending(path: "Archive.7z.001").path)
                    return true
                }
                return false
            }
            if cancel && stop { throw CancellationError() }
        })
        do {
            _ = try await ArchiveCreation.place([(first, ".7z.001"), (second, ".7z.002")],
                                                 named: "Archive", format: .sevenZip, in: destination,
                                                 conflict: .keepBoth, publicationOptions: options)
            Issue.record("Expected the second split part to fail")
        } catch { #expect(error.failure == (cancel ? .cancelled : .failed)) }
        if cancel { #expect(observation.withLock { $0.sawPriorOutput }) }
        else { #expect(observation.withLock { $0.chunks } == 1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: first) == firstBytes)
        if cancel { #expect(try Data(contentsOf: second) == secondBytes) }
    }

    @Test func cancelledSplitReplacementRestoresEveryOldVolume() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let source = try directory(folder.url, "Source")
        let destination = try directory(folder.url, "Destination")
        let firstBytes = Data("new first".utf8), secondBytes = Data(repeating: 31, count: 3_000_000)
        let oldFirstBytes = Data("old first".utf8), oldSecondBytes = Data("old second".utf8)
        let first = try file(source, "first", firstBytes), second = try file(source, "second", secondBytes)
        let oldFirst = try file(destination, "Archive.zip.001", oldFirstBytes)
        let oldSecond = try file(destination, "Archive.zip.002", oldSecondBytes)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            let stop = chunks.withLock { value in value += 1; return value == 2 }
            if stop { throw CancellationError() }
        })
        do {
            _ = try await ArchiveCreation.place([(first, ".zip.001"), (second, ".zip.002")],
                                                 named: "Archive", format: .zip, in: destination,
                                                 conflict: .replace, publicationOptions: options)
            Issue.record("Expected cancellation while replacing the second volume")
        } catch { #expect(error.failure == .cancelled) }
        #expect(chunks.withLock { $0 } == 2)
        #expect(try Data(contentsOf: oldFirst) == oldFirstBytes)
        #expect(try Data(contentsOf: oldSecond) == oldSecondBytes)
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["Archive.zip.001", "Archive.zip.002"])
    }

    @Test(arguments: [false, true])
    func trayFallbackPublishesCompleteFolderAndPreservesSource(export: Bool) throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let owned = try directory(folder.url, "Owned")
        let source = try directory(owned, "Result")
        let nested = try directory(source, "Nested")
        let destination = try directory(folder.url, "Destination")
        let bytes = Data(repeating: 101, count: 1_100_000)
        let original = try file(nested, "payload.bin", bytes)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in chunks.withLock { $0 += 1 } })
        let published: URL
        if export {
            // A collision must preserve the existing folder and number only the exported copy.
            let existing = try directory(destination, "Result")
            _ = try file(existing, "sentinel", Data("keep".utf8))
            published = try TrayExport.copy(source, into: destination, ownedRoot: owned, publicationOptions: options)
            #expect(published.lastPathComponent == "Result 2")
            #expect(try Data(contentsOf: existing.appending(path: "sentinel")) == Data("keep".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["Result", "Result 2"])
        } else {
            published = try TrayCollection.copy([source], named: "Collected", into: destination, publicationOptions: options)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Collected"])
        }
        let copied = published.appending(path: export ? "Nested/payload.bin" : "Result/Nested/payload.bin")
        #expect(try Data(contentsOf: copied) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(chunks.withLock { $0 } > 0, "The caller must exercise copy publication")
    }

    @Test(arguments: [false, true])
    func trayFallbackCancellationRemovesPartialPublicationAndPreservesSource(export: Bool) throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let owned = try directory(folder.url, "Owned")
        let source = try directory(owned, "Result")
        let destination = try directory(folder.url, "Destination")
        let bytes = Data(repeating: 43, count: 3_000_000)
        let original = try file(source, "payload.bin", bytes)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            chunks.withLock { $0 += 1 }
            throw CancellationError()
        })
        #expect(throws: CancellationError.self) {
            if export {
                _ = try TrayExport.copy(source, into: destination, ownedRoot: owned, publicationOptions: options)
            } else {
                _ = try TrayCollection.copy([source], named: "Collected", into: destination, publicationOptions: options)
            }
        }
        #expect(chunks.withLock { $0 } == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: original) == bytes)
    }
    private nonisolated final class RefusesPrivateStagingCleanup: FileManager, @unchecked Sendable {
        override func removeItem(at url: URL) throws {
            if url.lastPathComponent.hasPrefix(".stow-collect-") || url.lastPathComponent.hasPrefix(".stow-tray-export-") {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: url)
        }
    }

    @Test(arguments: [false, true])
    func trayReportsForeignPublicationAndPrivateStagingWhenBothCleanupPhasesFail(export: Bool) throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let owned = try directory(folder.url, "Owned")
        let destination = try directory(folder.url, "Destination")
        let bytes = Data(repeating: 83, count: 3_000_000)
        let original = try file(owned, "payload.bin", bytes)
        let publishedRoot = destination.appending(path: export ? "payload.bin" : "Collected")
        let publishedFile = export ? publishedRoot : publishedRoot.appending(path: "payload.bin")
        let foreignBytes = Data("foreign writer owns this output".utf8)
        let chunks = Mutex(0)
        let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
            chunks.withLock { $0 += 1 }
            try foreignBytes.write(to: publishedFile, options: .atomic)
            throw CancellationError()
        })
        do {
            if export {
                _ = try TrayExport.copy(original, into: destination, ownedRoot: owned,
                                        fileManager: RefusesPrivateStagingCleanup(), publicationOptions: options)
            } else {
                _ = try TrayCollection.copy([original], named: "Collected", into: destination,
                                            fileManager: RefusesPrivateStagingCleanup(), publicationOptions: options)
            }
            Issue.record("Expected both publication rollback and private staging cleanup to fail")
        } catch let retained as TrayCollection.RetainedCopies {
            #expect(retained.locations.contains { $0.path == publishedRoot.path })
            #expect(retained.locations.contains(retained.folder))
            #expect(retained.folder.deletingLastPathComponent().path == destination.path)
            #expect(retained.folder.lastPathComponent.hasPrefix(export ? ".stow-tray-export-" : ".stow-collect-"))
            #expect(FileManager.default.fileExists(atPath: retained.folder.path))
            if case ExclusivePublication.Failure.rollbackIncomplete(let paths) = retained.copyError {
                #expect(paths.contains { $0.path == publishedRoot.path })
            } else { Issue.record("Publication failure must preserve structured retained paths") }
        }
        #expect(chunks.withLock { $0 } == 1)
        #expect(try Data(contentsOf: publishedFile) == foreignBytes)
        #expect(try Data(contentsOf: original) == bytes)
    }

}
