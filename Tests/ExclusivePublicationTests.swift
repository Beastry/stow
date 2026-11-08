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

    @Test func nativeDirectoryRollbackRestoresUnchangedTree() throws {
        try fixture { source, target in
            let nested = source.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("unchanged".utf8).write(to: nested.appendingPathComponent("file"))
            try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("link").path, withDestinationPath: "file")
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target)
            #expect(!receipt.usedCopyFallback)
            try receipt.rollbackSynchronously()
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try String(contentsOf: nested.appendingPathComponent("file"), encoding: .utf8) == "unchanged")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: nested.appendingPathComponent("link").path) == "file")
        }
    }

    @Test func nativeDirectoryRollbackRetainsModifiedNestedFile() throws {
        try fixture { source, target in
            let nested = source.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: nested.appendingPathComponent("file"))
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target)
            let published = target.appendingPathComponent("nested/file")
            let handle = try FileHandle(forWritingTo: published)
            try handle.write(contentsOf: Data("modified".utf8)); try handle.close()
            do { try receipt.rollbackSynchronously(); Issue.record("Expected retained modified tree") }
            catch ExclusivePublication.Failure.rollbackIncomplete(let paths) { #expect(paths.contains(target)) }
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: published, encoding: .utf8) == "modified")
        }
    }

    @Test func nativeDirectoryRollbackRetainsAddedNestedChild() throws {
        try fixture { source, target in
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target)
            let added = target.appendingPathComponent("nested/foreign")
            try Data("foreign".utf8).write(to: added)
            do { try receipt.rollbackSynchronously(); Issue.record("Expected retained added child") }
            catch ExclusivePublication.Failure.rollbackIncomplete(let paths) { #expect(paths.contains(target)) }
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: added, encoding: .utf8) == "foreign")
        }
    }

    @Test func nativeDirectoryRollbackRetainsTreeWithRemovedNestedChild() throws {
        try fixture { source, target in
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("nested/file"))
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target)
            try FileManager.default.removeItem(at: target.appendingPathComponent("nested/file"))
            #expect(throws: ExclusivePublication.Failure.self) { try receipt.rollbackSynchronously() }
            #expect(FileManager.default.fileExists(atPath: target.path))
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
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

    @Test func explicitHelperPayloadIsNeverFilteredByPrefix() throws {
        try fixture { source, target in
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let bytes = Data("explicit arbitrary helper".utf8)
            try bytes.write(to: source.appendingPathComponent("._payload"))
            let receipt = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true))
            #expect(try Data(contentsOf: target.appendingPathComponent("._payload")) == bytes)
            try receipt.rollbackSynchronously()
        }
    }

    @Test func replacementOfExplicitHelperDuringCancelledCopyIsRetained() throws {
        try fixture { source, target in
            let helper = source.deletingLastPathComponent().appendingPathComponent("._selected")
            let published = target.deletingLastPathComponent().appendingPathComponent("._published")
            try Data(repeating: 7, count: 2_000_000).write(to: helper)
            let foreign = Data("foreign helper replacement".utf8)
            let options = ExclusivePublication.Options(forceCopy: true, didCopyChunk: { _ in
                try foreign.write(to: published, options: .atomic)
                throw CancellationError()
            })
            do {
                _ = try ExclusivePublication.publishSynchronously(source: helper, to: published, options: options)
                Issue.record("Expected retained replacement")
            } catch ExclusivePublication.Failure.rollbackIncomplete(let paths) { #expect(paths.contains(published)) }
            #expect(try Data(contentsOf: published) == foreign)
            #expect(try Data(contentsOf: helper) == Data(repeating: 7, count: 2_000_000))
        }
    }

    @Test func semanticCompanionRequiresAppleDoubleAndCorroboratedPairedAttributes() throws {
        try fixture { source, target in
            let fork = Data("resource fork payload".utf8)
            try Data("file".utf8).write(to: source)
            #expect(fork.withUnsafeBytes { setxattr(source.path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) } == 0)
            let companion = source.deletingLastPathComponent().appendingPathComponent("._source")
            #expect(copyfile(source.path, companion.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_METADATA)) == 0)
            let helper = try Data(contentsOf: companion)
            let parent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
            defer { close(parent) }
            #expect(try ExclusivePublication.isSemanticCompanion("._source", parent: parent, requireExFAT: false))
            try Data("arbitrary helper".utf8).write(to: companion)
            #expect(try !ExclusivePublication.isSemanticCompanion("._source", parent: parent, requireExFAT: false))
            try helper.write(to: companion)
            try FileManager.default.removeItem(at: source)
            #expect(try !ExclusivePublication.isSemanticCompanion("._source", parent: parent, requireExFAT: false))
            _ = target
        }
    }

    @Test func semanticCompanionRejectsExtraUnmatchedAttributesAndUnknownPayload() throws {
        try fixture { source, _ in
            try Data("source".utf8).write(to: source)
            let value = Array("extra attribute".utf8)
            #expect(value.withUnsafeBytes { setxattr(source.path, "com.stow.extra", $0.baseAddress, value.count, 0, 0) } == 0)
            let companion = source.deletingLastPathComponent().appendingPathComponent("._source")
            #expect(copyfile(source.path, companion.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_METADATA)) == 0)
            let packed = try Data(contentsOf: companion)
            let parent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
            defer { close(parent) }
            #expect(try ExclusivePublication.isSemanticCompanion("._source", parent: parent, requireExFAT: false))
            #expect(removexattr(source.path, "com.stow.extra", 0) == 0)
            #expect(try !ExclusivePublication.isSemanticCompanion("._source", parent: parent, requireExFAT: false))

            var unknownEntry = packed
            unknownEntry[29] = 10 // Unknown AppleDouble entry instead of Finder info.
            #expect(ExclusivePublication.strictCompanionAttributes(in: unknownEntry) == nil)
            var unknownPayload = packed
            unknownPayload.append(0x77)
            #expect(ExclusivePublication.strictCompanionAttributes(in: unknownPayload) == nil)
            if let marker = packed.range(of: Data([0x41, 0x54, 0x54, 0x52])) {
                var partialTable = packed
                partialTable[marker.lowerBound + 34] = 0x7f
                partialTable[marker.lowerBound + 35] = 0xff
                #expect(ExclusivePublication.strictCompanionAttributes(in: partialTable) == nil)
            } else { Issue.record("Packed fixture has no attribute table") }
        }
    }

    @Test func synchronousCancellationAcceptsLocalMutableState() throws {
        try fixture { source, target in
            try Data(repeating: 1, count: 2_000_000).write(to: source)
            var checks = 0
            #expect(throws: CancellationError.self) {
                _ = try ExclusivePublication.publishSynchronously(source: source, to: target, options: .init(forceCopy: true), checkCancellation: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                })
            }
            #expect(checks == 4)
            #expect(!FileManager.default.fileExists(atPath: target.path))
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
