import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Stow

@Suite("Edit plan")
struct EditPlanTests {
    private var listing: ArchiveListing {
        ArchiveListing(type: "zip", entries: [
            ListedEntry(path: "a", isFolder: false, size: 1),
            ListedEntry(path: "folder", isFolder: true, size: 0),
            ListedEntry(path: "folder/b", isFolder: false, size: 1),
        ])
    }

    @Test func detectsEditableFormats() {
        for (type, name, expected) in [("zip", "a.ZIP", EditableFormat.zip), ("7z", "a.7z", .sevenZip), ("tar", "a.tar", .tar)] {
            #expect(EditableFormat(listingType: type, fileName: name) == expected)
        }
        for name in ["a.001", "a.z01", "a.zip.001", "a.7z.001", "a.part1.rar", "part1.rar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.tar.xz"] {
            #expect(EditableFormat(listingType: "tar", fileName: name) == nil)
        }
        #expect(EditableFormat(listingType: "Rar5", fileName: "a.rar") == nil)
        #expect(EditableFormat(listingType: "gzip", fileName: "a") == nil)
    }

    @Test func addedThenDeletedCancels() throws {
        let steps = try EditPlan.steps(for: [.add(destinationFolder: "", items: ["new"]), .delete(paths: ["new"])], listing: listing, format: .zip)
        #expect(steps.map { $0.arguments.first } == ["t"])
    }

    @Test func deleteAfterRenameDeletesOriginal() throws {
        let steps = try EditPlan.steps(for: [.rename(from: "folder", to: "renamed"), .delete(paths: ["renamed"])], listing: listing, format: .zip)
        #expect(steps.map { $0.arguments.first } == ["d", "t"])
        #expect(steps[0].arguments.last == "folder")
    }

    @Test func consecutiveRenamesChain() throws {
        let steps = try EditPlan.steps(for: [.rename(from: "a", to: "b"), .rename(from: "b", to: "c")], listing: listing, format: .zip)
        #expect(steps[0].arguments.suffix(2) == ["a", "c"])
    }

    @Test func fixedStepOrderAndStagingPrefixes() throws {
        let ops: [EditOperation] = [.replace(path: "a", item: "replacement"), .rename(from: "folder", to: "renamed"),
                                     .add(destinationFolder: "renamed", items: ["new"])]
        let steps = try EditPlan.steps(for: ops, listing: listing, format: .zip)
        #expect(steps.map { $0.arguments.first } == ["d", "rn", "a", "t"])
        #expect(steps[2].sources.contains(.init(item: "new", path: "renamed/new")))
        #expect(Set(EditPlan.apply(ops, to: listing).entries.map(\.path)) == ["a", "renamed", "renamed/b", "renamed/new"])
    }

    @Test func dependentFolderRenamesAndNameSwaps() throws {
        let operations: [EditOperation] = [.rename(from: "folder", to: "renamed"),
                                            .rename(from: "renamed/b", to: "renamed/c")]
        let steps = try EditPlan.steps(for: operations, listing: listing, format: .zip)
        #expect(steps.filter { $0.arguments.first == "rn" }.map { Array($0.arguments.suffix(2)) }
            == [["folder", "renamed"], ["renamed/b", "renamed/c"]])
        let swapped = try EditPlan.steps(for: [.rename(from: "a", to: "temp"),
                                               .rename(from: "folder", to: "a"),
                                               .rename(from: "temp", to: "folder")], listing: listing, format: .zip)
        #expect(swapped.filter { $0.arguments.first == "rn" }.count == 3)
    }

    @Test func payloadsRoundTripAndFailureValuesStayStable() throws {
        let operations: [EditOperation] = [.add(destinationFolder: "folder", items: ["new"]),
                                            .replace(path: "a", item: "replacement"),
                                            .delete(paths: ["folder/b"]), .rename(from: "a", to: "c")]
        let request = EditRequest(operationID: "edit", format: .zip, operations: operations, password: "pw")
        let decoded = try JSONDecoder.engine.decode(EditRequest.self, from: JSONEncoder.engine.encode(request))
        #expect(decoded.version == 5)
        #expect(decoded.operations == operations)
        #expect(decoded.encryptNewItems && decoded.verify)
        let report = EditReport(size: 42, verified: true, listing: listing)
        let back = try JSONDecoder.engine.decode(EditReport.self, from: JSONEncoder.engine.encode(report))
        #expect(back.size == 42 && back.verified)
        #expect(back.listing.entries == listing.entries)
        #expect(EngineFailure.failed.rawValue == 8)
        #expect(EngineFailure.changedOnDisk.rawValue == 9)
    }

    @Test func refusesUnsafePathsAndConflicts() {
        let invalid: [[EditOperation]] = [
            [.add(destinationFolder: "../escape", items: ["new"])],
            [.add(destinationFolder: "", items: [""])],
            [.add(destinationFolder: "./folder", items: ["new"])],
            [.add(destinationFolder: "folder//nested", items: ["new"])],
            [.add(destinationFolder: "", items: ["a\0b"])],
            [.add(destinationFolder: "", items: ["/absolute"])],
            [.add(destinationFolder: "", items: ["@listfile"])],
            [.add(destinationFolder: "", items: ["nested/item"])],
            [.add(destinationFolder: "", items: ["a"])],
            [.add(destinationFolder: "a", items: ["new"])],
            [.add(destinationFolder: "", items: ["new", "new"])],
            [.rename(from: "folder", to: "folder/child")],
            [.rename(from: "a", to: "folder")],
            [.rename(from: "a", to: "a")],
            [.rename(from: "missing", to: "new")],
            [.rename(from: "a", to: "../new")],
            [.delete(paths: ["a", "a"])],
            [.delete(paths: ["missing"])],
            [.delete(paths: ["../a"])],
            [.replace(path: "folder", item: "new")],
            [.replace(path: "missing", item: "new")],
            [.replace(path: "a", item: "../new")],
        ]
        for operations in invalid {
            #expect(throws: (any Error).self) { try EditPlan.steps(for: operations, listing: listing, format: .zip) }
        }
    }

    @Test func refusesAmbiguousAndLegacyEntries() {
        var duplicate = listing
        duplicate.entries.append(duplicate.entries[0])
        #expect(throws: (any Error).self) { try EditPlan.steps(for: [], listing: duplicate, format: .zip) }
        var legacy = listing
        legacy.entries[2].rawPath = Data([0xFF])
        for op in [EditOperation.delete(paths: ["folder"]), .rename(from: "folder", to: "new"), .replace(path: "folder/b", item: "new")] {
            #expect(throws: (any Error).self) { try EditPlan.steps(for: [op], listing: legacy, format: .zip) }
        }
        var symlink = listing
        symlink.entries[0].isSymlink = true
        #expect(throws: (any Error).self) { try EditPlan.steps(for: [.replace(path: "a", item: "new")], listing: symlink, format: .zip) }
    }
}

@Suite("Editing", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled — run scripts/fetch-7zip.sh"))
struct EditingTests {
    private func hash(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    private func fixture(_ format: PackFormat, in root: URL, password: String? = nil) async throws -> URL {
        let source = root.appending(path: "source")
        let output = root.appending(path: "output")
        let scratch = root.appending(path: "scratch")
        for folder in [source, output, scratch, source.appending(path: "folder"), source.appending(path: "removeFolder")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for (path, text) in ["a": "old", "remove": "remove", "folder/b": "b", "removeFolder/child": "child"] {
            try Data(text.utf8).write(to: source.appending(path: path))
        }
        let sevenZip = try #require(SevenZip.bundled())
        let request = CreateRequest(operationID: UUID().uuidString, archiveName: "sample", format: format, password: password, verify: true)
        _ = try await sevenZip.create(request, from: source, into: output, work: scratch) { _ in }
        return output.appending(path: "sample." + format.fileExtension)
    }

    @Test(arguments: [PackFormat.zip, .sevenZip, .tar])
    func privateDescriptorCanBeListedAndRead(format: PackFormat) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await fixture(format, in: root)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let input = ArchiveInput.descriptor(handle, name: archive.lastPathComponent)
        let engine = try #require(SevenZip.bundled())
        let listing = try await engine.list(input)
        #expect(listing.entries.contains { $0.path == "folder/b" })
        try await engine.test(input) { _ in }
    }

    @Test(arguments: [PackFormat.zip, .sevenZip])
    func encryptedPrivateDescriptorRetainsPasswordBehavior(format: PackFormat) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await fixture(format, in: root, password: "secret")
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let engine = try #require(SevenZip.bundled())
        let input = ArchiveInput.descriptor(handle, name: archive.lastPathComponent)
        try await engine.test(input, password: "secret") { _ in }
        do {
            try await engine.test(input, password: "wrong") { _ in }
            Issue.record("Wrong password succeeded")
        } catch { #expect(error.failure == .wrongPassword) }
    }

    private func staged(_ root: URL, path: String, text: String) throws -> TreeStream.Item {
        let url = root.appending(path: UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return TreeStream.Item(source: url, path: path)
    }

    @Test(arguments: [PackFormat.zip, .sevenZip, .tar])
    func editsRoundTrip(format: PackFormat) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(format, in: folder.url)
        let identity = try FileIdentity(of: archive)
        let items = try [staged(folder.url, path: "root.txt", text: "root"),
                         staged(folder.url, path: "nested.txt", text: "nested"),
                         staged(folder.url, path: "replacement", text: "new")]
        let ops: [EditOperation] = [.add(destinationFolder: "", items: ["root.txt"]),
                                    .add(destinationFolder: "folder", items: ["nested.txt"]),
                                    .replace(path: "a", item: "replacement"),
                                    .delete(paths: ["remove", "removeFolder"]),
                                    .rename(from: "a", to: "renamed.txt"), .rename(from: "folder", to: "renamedFolder")]
        let listing = try await ArchiveSaver.save(archive: archive, operations: ops, items: items, identity: identity)
        #expect(Set(listing.entries.filter { !$0.isFolder }.map(\.path)) == ["root.txt", "renamed.txt", "renamedFolder/b", "renamedFolder/nested.txt"])
        let sevenZip = try #require(SevenZip.bundled())
        let actual = try await ArchiveEngine.shared.list(archive)
        #expect(actual.entries == listing.entries)
        let extracted = folder.url.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try await sevenZip.extract(archive, into: extracted) { _ in }
        for (path, expected) in ["root.txt": "root", "renamed.txt": "new", "renamedFolder/b": "b", "renamedFolder/nested.txt": "nested"] {
            #expect(try String(contentsOf: extracted.appending(path: path), encoding: .utf8) == expected)
        }
        #expect(!FileManager.default.fileExists(atPath: extracted.appending(path: "removeFolder").path))
    }

    private func jarFixture(_ name: String, in folder: URL) throws -> URL {
        let fixtures = try #require(Bundle(for: JARFixtureLocator.self).url(forResource: "Fixtures", withExtension: nil))
        let destination = folder.appending(path: name)
        try FileManager.default.copyItem(at: fixtures.appending(path: "JAR/" + name), to: destination)
        return destination
    }

    @Test @MainActor func ordinaryJarEditsUndoRedoAndSavePreserveNestedDependency() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try jarFixture("Ordinary.jar", in: folder.url)
        let before = try hash(archive)
        let base = try await ArchiveEngine.shared.list(archive)
        let session = EditSession(base: base, url: archive)
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        #expect(session.format == .zip)
        #expect(!session.hasJARSignature)

        let unpacked = folder.url.appending(path: "before")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
        let engine = try #require(SevenZip.bundled())
        _ = try await engine.extract(archive, into: unpacked) { _ in }
        let nestedPath = "lib/dependency.jar"
        let nestedBefore = try hash(unpacked.appending(path: nestedPath))
        let replacement = folder.url.appending(path: "replacement.txt")
        let addition = folder.url.appending(path: "added.txt")
        try Data("replacement\n".utf8).write(to: replacement)
        try Data("new entry\n".utf8).write(to: addition)

        #expect(session.add([addition], into: ""))
        session.replace("payload.txt", with: replacement)
        session.delete(["remove.txt"])
        session.rename("move.txt", to: "renamed.txt")
        let planned = session.pending
        #expect(session.operations.count == 4)
        for _ in 0..<4 { undo.undo() }
        #expect(session.pending.entries == base.entries)
        #expect(try hash(archive) == before)
        for _ in 0..<4 { undo.redo() }
        #expect(session.pending.entries == planned.entries)
        #expect(try hash(archive) == before)
        #expect(await session.save(password: nil))
        #expect(session.url?.lastPathComponent == "Ordinary.jar")
        #expect(!undo.canUndo && !undo.canRedo)

        let output = folder.url.appending(path: "after")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        _ = try await engine.extract(archive, into: output) { _ in }
        for (path, content) in ["added.txt": "new entry\n", "payload.txt": "replacement\n", "renamed.txt": "rename this\n"] {
            #expect(try Data(contentsOf: output.appending(path: path)) == Data(content.utf8))
        }
        for path in ["remove.txt", "move.txt"] {
            #expect(!FileManager.default.fileExists(atPath: output.appending(path: path).path))
        }
        let dependency = output.appending(path: nestedPath)
        #expect(try hash(dependency) == nestedBefore)
        let listing = try await ArchiveEngine.shared.list(dependency)
        #expect(listing.entries.contains { $0.path == "dep.txt" })
    }

    @Test @MainActor func signedJarRetainsSignatureFilesButEditingInvalidatesPayloadDigest() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try jarFixture("Signed.jar", in: folder.url)
        let before = try hash(archive)
        let replacement = try staged(folder.url, path: "replacement", text: "replacement")
        let operations: [EditOperation] = [.replace(path: "payload.txt", item: "replacement")]
        await #expect(throws: (any Error).self) {
            try await ArchiveSaver.save(archive: archive, operations: operations, items: [replacement], faults: .failBeforeSwap)
        }
        #expect(try hash(archive) == before)

        let engine = try #require(SevenZip.bundled())
        let original = folder.url.appending(path: "original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        _ = try await engine.extract(archive, into: original) { _ in }
        let manifest = try Data(contentsOf: original.appending(path: "META-INF/MANIFEST.MF"))
        let payload = try Data(contentsOf: original.appending(path: "payload.txt"))
        let digest = Data(SHA256.hash(data: payload)).base64EncodedString()
        #expect(String(decoding: manifest, as: UTF8.self).contains("Name: payload.txt\r\nSHA-256-Digest: " + digest))

        let listing = try await ArchiveEngine.shared.list(archive)
        let model = BrowserModel(archive: Archive(listing: listing, url: archive))
        #expect(model.editSession.hasJARSignature)
        model.editSession.replace("payload.txt", with: replacement.source)
        var prompted: [String] = []
        let cancel: (Prompt, NSWindow?) async -> Prompt.Answer = { prompt, _ in
            prompted.append(prompt.choices[0].title)
            #expect(prompt.choices[1].role == .cancel)
            return .init(choice: 1, suppress: false)
        }
        #expect(!(await model.saveEdits(present: cancel)))
        #expect(!(await model.saveCopyOfArchive(present: cancel)))
        #expect(prompted == [String(localized: "Save"), String(localized: "Save a Copy")])
        #expect(try hash(archive) == before)
        #expect(model.editSession.operations.count == 1)
        #expect(await model.saveEdits { _, _ in .init(choice: 0, suppress: false) })
        let edited = folder.url.appending(path: "edited")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: false)
        _ = try await engine.extract(archive, into: edited) { _ in }
        for path in ["META-INF/MANIFEST.MF", "META-INF/STOWFIXT.SF", "META-INF/STOWFIXT.RSA"] {
            #expect(try Data(contentsOf: edited.appending(path: path)) == Data(contentsOf: original.appending(path: path)))
        }
        let editedPayload = try Data(contentsOf: edited.appending(path: "payload.txt"))
        #expect(editedPayload == Data("replacement".utf8))
        #expect(Data(SHA256.hash(data: editedPayload)).base64EncodedString() != digest)
    }

    @Test func jarWithDuplicateDirectoriesRejectsWritesAndPreservesSourceHash() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = folder.url.appending(path: "Duplicates.jar")
        try ZipFixture(entries: [
            .folder("META-INF"), .folder("META-INF"), .file("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\n\r\n"),
            .file("payload.txt", "original")
        ]).write(to: archive)
        let before = try hash(archive)
        let listing = try await ArchiveEngine.shared.list(archive)
        #expect(listing.entries.filter { $0.path == "META-INF" && $0.isFolder }.count == 2)
        let output = folder.url.appending(path: "read")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let engine = try #require(SevenZip.bundled())
        _ = try await engine.extract(archive, into: output) { _ in }
        #expect(try Data(contentsOf: output.appending(path: "payload.txt")) == Data("original".utf8))
        await #expect(throws: (any Error).self) {
            try await ArchiveSaver.save(archive: archive, operations: [.delete(paths: ["payload.txt"])], items: [])
        }
        #expect(try hash(archive) == before)
    }

    @Test(arguments: [PackFormat.zip, .sevenZip, .tar])
    func addsStagedDirectories(format: PackFormat) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(format, in: folder.url)
        let directory = folder.url.appending(path: "newFolder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "child")
        try Data("directory contents".utf8).write(to: file)
        let items = [TreeStream.Item(source: directory, path: "newFolder"),
                     TreeStream.Item(source: file, path: "newFolder/child")]
        let result = try await ArchiveSaver.save(archive: archive,
                                                operations: [.add(destinationFolder: "folder", items: ["newFolder"])], items: items)
        #expect(result.entries.contains { $0.path == "folder/newFolder/child" })
        let extracted = folder.url.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let sevenZip = try #require(SevenZip.bundled())
        _ = try await sevenZip.extract(archive, into: extracted) { _ in }
        #expect(try String(contentsOf: extracted.appending(path: "folder/newFolder/child"), encoding: .utf8) == "directory contents")
    }

    @Test(arguments: [PackFormat.zip, .sevenZip])
    func encryptedEditsRequirePasswordAndEncryptNewItems(format: PackFormat) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(format, in: folder.url, password: "secret")
        let item = try staged(folder.url, path: "new", text: "encrypted addition")
        let original = try hash(archive)
        await expectEngineFailure(.wrongPassword) {
            try await ArchiveSaver.save(archive: archive, operations: [.add(destinationFolder: "", items: ["new"])], items: [item], password: "wrong")
        }
        #expect(try hash(archive) == original)
        await expectEngineFailure(.passwordRequired) {
            try await ArchiveSaver.save(archive: archive, operations: [.delete(paths: ["a"])], items: [])
        }
        #expect(try hash(archive) == original)
        let result = try await ArchiveSaver.save(archive: archive, operations: [.add(destinationFolder: "", items: ["new"])], items: [item], password: "secret")
        #expect(result.entries.first { $0.path == "new" }?.isEncrypted == true)
        let sevenZip = try #require(SevenZip.bundled())
        if format == .sevenZip {
            await expectEngineFailure(.passwordRequired) { try await sevenZip.list(archive) }
        }
        let extracted = folder.url.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try await sevenZip.extract(archive, into: extracted, password: "secret") { _ in }
        #expect(try String(contentsOf: extracted.appending(path: "new"), encoding: .utf8) == "encrypted addition")
    }

    @Test(arguments: [PackFormat.zip, .sevenZip, .tar])
    func failuresKeepOriginalBytes(format: PackFormat) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(format, in: folder.url)
        let item = try staged(folder.url, path: "new", text: "new bytes")
        let original = try hash(archive)
        for fault in [ArchiveSaver.Faults.cancelDuringEngine, .cancelDuringTransfer, .failWrite, .failBeforeSwap] {
            do {
                _ = try await ArchiveSaver.save(archive: archive, operations: [.add(destinationFolder: "", items: ["new"])], items: [item], faults: fault)
                Issue.record("Fault injection unexpectedly succeeded")
            } catch {
                switch fault {
                case .cancelDuringEngine, .cancelDuringTransfer: #expect(error.failure == .cancelled)
                default: #expect(error.failure == .failed)
                }
            }
            #expect(try hash(archive) == original)
        }
    }

    @Test func replacementSourceMustBeAFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(.zip, in: folder.url)
        let before = try hash(archive)
        let source = folder.url.appending(path: "directory")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            try await ArchiveSaver.save(archive: archive, operations: [.replace(path: "a", item: "replacement")],
                                        items: [TreeStream.Item(source: source, path: "replacement")])
        }
        #expect(try hash(archive) == before)
    }

    @Test func identityDetectsContentChangesWithSameSizeAndDate() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "bytes")
        try Data(repeating: 0x41, count: 150_000).write(to: file)
        let identity = try FileIdentity(of: file)
        let modified = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 149_999)
        try handle.write(contentsOf: Data([0x42]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(try FileIdentity(of: file) != identity)
    }

    @Test func changedOnDiskRefusesSave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = try await fixture(.zip, in: folder.url)
        let identity = try FileIdentity(of: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("external modification".utf8))
        try handle.close()
        let changed = try hash(archive)
        await expectEngineFailure(.changedOnDisk) {
            try await ArchiveSaver.save(archive: archive, operations: [.delete(paths: ["a"])], items: [], identity: identity)
        }
        #expect(try hash(archive) == changed)
    }

    @Test func verificationFailureKeepsOriginalBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let archive = folder.url.appending(path: "damaged.zip")
        try ZipFixture(entries: [.file("a", "contents whose CRC will fail")]).write(to: archive)
        var bytes = try Data(contentsOf: archive)
        // Stored local header (30 bytes), one-byte filename, then payload. Leave listing intact.
        bytes[31] ^= 0xFF
        try bytes.write(to: archive)
        let before = try hash(archive)
        await #expect(throws: (any Error).self) {
            try await ArchiveSaver.save(archive: archive, operations: [], items: [])
        }
        #expect(try hash(archive) == before)
    }
}

private final class JARFixtureLocator: NSObject {}
