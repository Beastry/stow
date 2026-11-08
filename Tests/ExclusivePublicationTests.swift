import Foundation
import Darwin
import Testing
@testable import Stow

@Suite("Exclusive publication")
struct ExclusivePublicationTests {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("source"), root.appendingPathComponent("target"))
    }

    @Test func fallbackCopiesBytesAndPreservesSourceThenRollsBack() throws {
        try fixture { source, target in
            let bytes = Data(repeating: 73, count: 2_500_000)
            try bytes.write(to: source)
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            #expect(receipt.usedCopyFallback)
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Data(contentsOf: target) == bytes)
            try receipt.rollbackSynchronously()
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test func exclusiveCreationRefusesFileAndDirectoryCollisions() throws {
        for directory in [false, true] {
            try fixture { source, target in
                try Data("source".utf8).write(to: source)
                if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                else { try Data("existing".utf8).write(to: target) }
                do {
                    _ = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
                    Issue.record("Expected a collision")
                } catch ExclusivePublication.Failure.collision { }
                #expect(FileManager.default.fileExists(atPath: target.path))
                if !directory { #expect(try String(contentsOf: target, encoding: .utf8) == "existing") }
            }
        }
    }

    @Test func racingWriterWinsWithoutBeingOverwritten() throws {
        try fixture { source, target in
            try Data("incoming".utf8).write(to: source)
            let options = ExclusivePublication.Options(forceCopy: true, checkCancellation: {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try Data("racing writer".utf8).write(to: target, options: .withoutOverwriting)
                }
            })
            do {
                _ = try ExclusivePublication.publishSynchronously(source: source, to: target, options: options)
                Issue.record("Expected collision with racing writer")
            } catch ExclusivePublication.Failure.collision { }
            #expect(try String(contentsOf: target, encoding: .utf8) == "racing writer")
            #expect(try String(contentsOf: source, encoding: .utf8) == "incoming")
        }
    }

    @Test func cancellationDuringBoundedCopyRemovesOnlyOwnedOutput() throws {
        try fixture { source, target in
            let bytes = Data(repeating: 9, count: 3_000_000)
            try bytes.write(to: source)
            let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in throw CancellationError() })
            #expect(throws: CancellationError.self) {
                _ = try ExclusivePublication.publishSynchronously(source: source, to: target, options: options)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test func rollbackRetainsModifiedFile() throws {
        try fixture { source, target in
            try Data("original".utf8).write(to: source)
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            let handle = try FileHandle(forWritingTo: target)
            try handle.write(contentsOf: Data("changed!".utf8)); try handle.close()
            #expect(throws: ExclusivePublication.Failure.self) { try receipt.rollbackSynchronously() }
            #expect(try String(contentsOf: target, encoding: .utf8) == "changed!")
        }
    }

    @Test func rollbackRetainsForeignReplacement() throws {
        try fixture { source, target in
            try Data("original".utf8).write(to: source)
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            try Data("foreign".utf8).write(to: target, options: .atomic)
            #expect(throws: ExclusivePublication.Failure.self) { try receipt.rollbackSynchronously() }
            #expect(try String(contentsOf: target, encoding: .utf8) == "foreign")
        }
    }

    @Test func directoryRollbackKeepsUnknownChildrenAndReportsPartialPath() throws {
        try fixture { source, target in
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("owned".utf8).write(to: source.appendingPathComponent("owned"))
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            try Data("foreign".utf8).write(to: target.appendingPathComponent("foreign"))
            do { try receipt.rollbackSynchronously(); Issue.record("Expected retained directory") }
            catch ExclusivePublication.Failure.rollbackIncomplete(let paths) { #expect(paths.contains(target)) }
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("owned").path))
            #expect(try String(contentsOf: target.appendingPathComponent("foreign"), encoding: .utf8) == "foreign")
        }
    }

    @Test func fallbackRefusesSymlinksWithoutFollowingThem() throws {
        try fixture { source, target in
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: source.deletingLastPathComponent())
            #expect(throws: ExclusivePublication.Failure.self) {
                _ = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func nativeRenamePreservesSymlinkAndCanRollBack() throws {
        try fixture { source, target in
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: source.deletingLastPathComponent())
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target)
            #expect(!receipt.usedCopyFallback)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == source.deletingLastPathComponent().path)
            try receipt.rollbackSynchronously()
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == source.deletingLastPathComponent().path)
        }
    }

    @Test func fallbackPreservesModeTimestampAndExtendedAttribute() throws {
        try fixture { source, target in
            try Data("metadata".utf8).write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
            let value = Array("attribute".utf8)
            #expect(value.withUnsafeBytes { setxattr(source.path, "com.stow.publication-test", $0.baseAddress, value.count, 0, 0) } == 0)
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            var original = stat(), copied = stat()
            #expect(lstat(source.path, &original) == 0); #expect(lstat(target.path, &copied) == 0)
            #expect(original.st_mode == copied.st_mode)
            #expect(original.st_mtimespec.tv_sec == copied.st_mtimespec.tv_sec)
            var result = [UInt8](repeating: 0, count: value.count)
            #expect(getxattr(target.path, "com.stow.publication-test", &result, result.count, 0, 0) == value.count)
            #expect(result == value)
            receipt.commit()
        }
    }
}
