import Foundation
import Testing
@testable import Stow

@Suite("Signed app contained links")
@MainActor
struct SignedContainedLinkTests {
    /// Pins the whole engine → stream → second audit → installer path, without private DMGs.
    @Test func installingParentRelativeLinksPreservesTheOriginalSeal() async throws {
        _ = try #require(SevenZip.bundled())
        let helpers = InstallEngineTests()
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let build = folder.url.appending(path: "Build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
        let app = try helpers.makeApp(named: "LinkSeal", version: "1.0", in: build)
        let resources = app.appending(path: "Contents/Resources/public")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("sealed payload".utf8).write(to: resources.appending(path: "data"))
        for (name, target) in [("public", "../Resources/public"), ("public-copy", "../MacOS/public")] {
            try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Contents/MacOS/" + name).path,
                                                      withDestinationPath: target)
        }
        try helpers.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try helpers.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        let walker = try #require(FileManager.default.enumerator(at: app,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]))
        var entries: [ZipFixture.Entry] = []
        while let url = walker.nextObject() as? URL {
            let relative = app.lastPathComponent + "/" + url.path.dropFirst(app.path.count + 1)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                entries.append(.symlink(relative, to: try FileManager.default.destinationOfSymbolicLink(atPath: url.path)))
            } else if values.isDirectory == true {
                entries.append(.folder(relative))
            } else {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
                entries.append(.init(name: relative, data: try Data(contentsOf: url), mode: 0o100000 | permissions))
            }
        }
        let zip = folder.url.appending(path: "SignedLinks.zip")
        try ZipFixture(entries: entries).write(to: zip)
        let archive = Archive(listing: try await ArchiveEngine.shared.list(zip), url: zip)
        let entry = try #require(archive.entry(at: app.lastPathComponent))
        let applications = folder.url.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: false)
        let outcome = try await Installer.installApp(entry, from: archive, into: applications,
            removeQuarantine: false, ask: { _ in .proceed }, onProgress: { _ in })

        #expect(outcome.isComplete)
        #expect(outcome.verdict == .adHoc)
        #expect(CodeSignature.assess(outcome.app) == .adHoc)
        for (name, target) in [("public", "../Resources/public"), ("public-copy", "../MacOS/public")] {
            let link = outcome.app.appending(path: "Contents/MacOS/" + name)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target)
            #expect(try String(contentsOf: link.appending(path: "data"), encoding: .utf8) == "sealed payload")
        }
        try helpers.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", outcome.app.path])
    }
}
