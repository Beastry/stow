import Foundation
import Testing
@testable import Stow

@Suite("Contained archive links")
struct ContainedLinkRestorationTests {
    @Test(arguments: [("σ", "ς"), ("Straße", "STRASSE"), ("ﬀ", "FF"), ("é", "e\u{301}")])
    func rejectsFilesystemEquivalentNames(names: (String, String)) throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let capability = try #require(ContainedLinkRestoration(in: folder.url))
        try write("target", "sealed", in: folder.url)
        try write(names.0, "", in: folder.url)
        let first = RemovedLink(path: names.0, target: "target")
        let second = RemovedLink(path: names.1, target: "target")
        #expect(ContainedLinkRestoration.collisionKey(names.0) == ContainedLinkRestoration.collisionKey(names.1))
        #expect(capability.finish([first, second], verified: [first, second]) == [first, second])
        #expect(try Data(contentsOf: folder.url.appending(path: names.0)).isEmpty)
    }

    @Test func verifiesAPFSTargetTerminatorsWithoutAcceptingAmbiguousBytes() {
        let link = RemovedLink(path: "MiniMax Design.app/Contents/MacOS/sq.version", target: "../Resources/sq.version")
        var entry = ListedEntry(path: link.path, isFolder: false, isSymlink: true,
                                linkTarget: link.target, size: Int64(link.target.utf8.count + 1))
        #expect(SevenZip.refusedLinkBytesMatch(link, entry: entry, bytes: link.target + "\0"))
        #expect(!SevenZip.refusedLinkBytesMatch(link, entry: entry, bytes: link.target + "\0\0"))
        #expect(!SevenZip.refusedLinkBytesMatch(link, entry: entry, bytes: link.target + "x"))
        entry.linkTarget = nil
        #expect(!SevenZip.refusedLinkBytesMatch(link, entry: entry, bytes: link.target + "\0"))
        entry.size -= 1
        #expect(SevenZip.refusedLinkBytesMatch(link, entry: entry, bytes: link.target))
    }

    @Test func restoresDependentLinksInEitherOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let capability = try #require(ContainedLinkRestoration(in: folder.url))
        try write("Resources/payload", "sealed", in: folder.url)
        let first = RemovedLink(path: "Bin/first", target: "../Bin/second")
        let second = RemovedLink(path: "Bin/second", target: "../Resources/payload")
        for link in [first, second] { try write(link.path, "", in: folder.url) }

        #expect(capability.finish([first, second], verified: [first, second]).isEmpty)
        #expect(try String(contentsOf: folder.url.appending(path: first.path), encoding: .utf8) == "sealed")
        #expect(try PathContainment.audit(staging: folder.url).removedLinks.isEmpty)
    }

    @Test func rejectsEscapesAbsoluteTargetsCyclesAndMissingTargets() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let capability = try #require(ContainedLinkRestoration(in: folder.url))
        let links = [RemovedLink(path: "escape", target: "../outside"),
                     RemovedLink(path: "absolute", target: "/etc/passwd"),
                     RemovedLink(path: "one", target: "two"), RemovedLink(path: "two", target: "one"),
                     RemovedLink(path: "missing", target: "absent")]
        for link in links { try write(link.path, "", in: folder.url) }
        #expect(capability.finish(links, verified: Set(links)) == links)
        #expect(folder.contents().isEmpty)
    }

    @Test func neverTraversesDestinationOrTargetSymlinkAncestors() throws {
        let folder = try TemporaryFolder()
        let outside = try TemporaryFolder()
        defer { folder.cleanUp(); outside.cleanUp() }
        let capability = try #require(ContainedLinkRestoration(in: folder.url))
        try write("untouched", "", in: outside.url)
        try FileManager.default.createSymbolicLink(atPath: folder.url.appending(path: "jump").path,
                                                  withDestinationPath: outside.url.path)
        try write("Resources/payload", "sealed", in: folder.url)
        try write("link", "", in: folder.url)
        let destination = RemovedLink(path: "jump/untouched", target: "../Resources/payload")
        let target = RemovedLink(path: "link", target: "jump/../Resources/payload")
        #expect(capability.finish([destination, target], verified: [destination, target]) == [destination, target])
        #expect(try Data(contentsOf: outside.url.appending(path: "untouched")).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: outside.url.appending(path: "untouched").path)[.type]
                as? FileAttributeType == .typeRegular)
    }

    @Test func preservesForeignFilesUnverifiedPlaceholdersAndCollisions() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let capability = try #require(ContainedLinkRestoration(in: folder.url))
        try write("target", "payload", in: folder.url)
        try write("foreign", "keep", in: folder.url)
        try write("unverified", "", in: folder.url)
        try write("collision", "", in: folder.url)
        try write("hard", "", in: folder.url)
        try FileManager.default.linkItem(at: folder.url.appending(path: "hard"),
                                        to: folder.url.appending(path: "hard-copy"))
        let foreign = RemovedLink(path: "foreign", target: "target")
        let unverified = RemovedLink(path: "unverified", target: "target")
        let collision = RemovedLink(path: "collision", target: "target")
        let alias = RemovedLink(path: "COLLISION", target: "target")
        let hard = RemovedLink(path: "hard", target: "target")
        let links = [foreign, unverified, collision, alias, hard]
        #expect(capability.finish(links, verified: [foreign, collision, alias, hard]) == links)
        #expect(try String(contentsOf: folder.url.appending(path: "foreign"), encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "unverified").path))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "collision").path))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "hard").path))
    }

    @Test func preexistingOrReplacedRootsDoNotGrantRestoration() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        try write("existing", "", in: folder.url)
        #expect(ContainedLinkRestoration(in: folder.url) == nil)
        let root = folder.url.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let capability = try #require(ContainedLinkRestoration(in: root))
        try FileManager.default.moveItem(at: root, to: folder.url.appending(path: "old-root"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try write("target", "payload", in: root)
        try write("link", "", in: root)
        let link = RemovedLink(path: "link", target: "target")
        #expect(capability.finish([link], verified: [link]) == [link])
        #expect(try Data(contentsOf: root.appending(path: "link")).isEmpty)
    }

    @Test func restoresRealArchiveParentLinksAndRetainsOutwardRejection() async throws {
        let sevenZip = try #require(SevenZip.bundled())
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let zip = folder.url.appending(path: "links.zip")
        try ZipFixture(entries: [.file("App/Resources/public/data", "sealed"),
                                 .symlink("App/MacOS/public", to: "../Resources/public"),
                                 .symlink("App/MacOS/escape", to: "../../../../outside")]).write(to: zip)
        let out = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let rejected = try await sevenZip.extract(zip, into: out) { _ in }
        #expect(rejected == [RemovedLink(path: "App/MacOS/escape", target: "../../../../outside")])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appending(path: "App/MacOS/public").path)
                == "../Resources/public")
        #expect(try String(contentsOf: out.appending(path: "App/MacOS/public/data"), encoding: .utf8) == "sealed")
        #expect(try PathContainment.audit(staging: out).removedLinks.isEmpty)
    }

    @Test(arguments: ["-Folder", "@Folder"])
    func targetReadsTreatEntryNamesAsLiterals(folderName: String) async throws {
        let sevenZip = try #require(SevenZip.bundled())
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let zip = folder.url.appending(path: "literal-paths.zip")
        try ZipFixture(entries: [.file("target", "sealed"),
                                 .symlink(folderName + "/link", to: "../target")]).write(to: zip)
        let out = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let rejected = try await sevenZip.extract(zip, into: out) { _ in }
        #expect(rejected.isEmpty)
        let link = out.appending(path: folderName + "/link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../target")
        #expect(try String(contentsOf: link, encoding: .utf8) == "sealed")
        #expect(try PathContainment.audit(staging: out).removedLinks.isEmpty)
    }

    @Test func duplicateArchivePathsCannotAuthorizePlaceholderReplacement() async throws {
        let sevenZip = try #require(SevenZip.bundled())
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let zip = folder.url.appending(path: "collision.zip")
        try ZipFixture(entries: [.file("Resources/data", "payload"),
                                 .symlink("Bin/link", to: "../Resources/data"),
                                 .file("Bin/link", "")]).write(to: zip)
        let out = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let rejected = try await sevenZip.extract(zip, into: out) { _ in }
        #expect(rejected.contains { $0.path == "Bin/link" })
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: out.appending(path: "Bin/link").path)) == nil)
    }

    @Test(arguments: [("Straße", "STRASSE"), ("σ", "ς"), ("ﬀ", "FF")])
    func archiveAliasesCannotReplaceTheOriginalEmptyFile(names: (String, String)) async throws {
        let sevenZip = try #require(SevenZip.bundled())
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let zip = folder.url.appending(path: "aliases.zip")
        try ZipFixture(entries: [.file("Folder/" + names.0, ""),
                                 .symlink("Folder/" + names.1, to: "../target"),
                                 .file("target", "sealed")]).write(to: zip)
        let out = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let rejected = try await sevenZip.extract(zip, into: out) { _ in }
        #expect(rejected.contains { $0.path == "Folder/" + names.1 })
        let original = out.appending(path: "Folder/" + names.0)
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.type]
                as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: original).isEmpty)
    }

    @Test func exactEntryReadsHaveABoundedOutputBuffer() async throws {
        let sevenZip = try #require(SevenZip.bundled())
        let result = try await sevenZip.run(["i"], input: nil, password: nil, outputLimit: 16)
        #expect(result.output.utf8.count <= 17)
    }

    private func write(_ path: String, _ text: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
