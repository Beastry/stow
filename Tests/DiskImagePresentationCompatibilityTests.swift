import CoreGraphics
import DSStore
import Foundation
import Testing
@testable import Stow

@Suite("Disk image presentation compatibility")
@MainActor
struct DiskImagePresentationCompatibilityTests {
    @Test func rootBackgroundPicturesArePresentationWhileOrdinaryHiddenFilesStayContent() {
        let listing = ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Vol/Tool.app/Contents/Info.plist", isFolder: false, size: 10),
            ListedEntry(path: "Vol/.DS_Store", isFolder: false, size: 100),
            ListedEntry(path: "Vol/.background.tiff", isFolder: false, size: 200),
            ListedEntry(path: "Vol/.background.PNG", isFolder: false, size: 300),
            ListedEntry(path: "Vol/.background.notes", isFolder: false, size: 400),
            ListedEntry(path: "Vol/.background.extra.png", isFolder: false, size: 400),
            ListedEntry(path: "Vol/.holiday.png", isFolder: false, size: 400),
            ListedEntry(path: "Vol/Notes/.background.png", isFolder: false, size: 400),
        ])
        let archive = Archive(listing: listing, url: URL(filePath: "/tmp/Example.dmg"))
        #expect(archive.presentationFiles["Vol/.background.tiff"] == 200)
        #expect(archive.presentationFiles["Vol/.background.PNG"] == 300)
        #expect(archive.installerExtras.contains("Vol/.background.tiff"))
        #expect(archive.entry(at: "Vol/.background.tiff")?.isHelper == true)
        #expect(archive.children(of: "Vol").contains { $0.name == ".background.notes" })
        #expect(archive.children(of: "Vol").contains { $0.name == ".background.extra.png" })
        #expect(archive.children(of: "Vol").contains { $0.name == ".holiday.png" })
        #expect(archive.entry(at: "Vol/Notes/.background.png")?.isHelper == false)

        let zip = Archive(listing: ArchiveListing(type: "zip", entries: listing.entries), url: URL(filePath: "/tmp/Example.zip"))
        #expect(zip.installerExtras.isEmpty)
        #expect(zip.entry(at: "Vol/.background.tiff")?.isHelper == false)
    }

    @Test func recognizedAliasesHaveOneClassificationAcrossPresentationAndExtraction() {
        let listing = ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Vol/Tool.app/Contents/Info.plist", isFolder: false, size: 10),
            ListedEntry(path: "Vol/Applications", isFolder: false, size: 596),
            ListedEntry(path: "Vol/Read Me.txt", isFolder: false, size: 50),
        ])
        let target = DiskImageLayout.DropTarget(path: "Vol/Applications", folder: "/Applications")
        let archive = Archive(listing: listing, url: URL(filePath: "/tmp/Example.dmg"), aliasDropTargets: [target])
        #expect(archive.dropTargets == [target])
        #expect(archive.installerExtras.contains(target.path))
        #expect(archive.entry(at: target.path)?.isHelper == true)
        #expect(!archive.children(of: "Vol").contains { $0.path == target.path })
        #expect(archive.children(of: "Vol", includingHelpers: true).contains { $0.path == target.path })
        #expect(archive.children(of: "Vol").contains { $0.name == "Read Me.txt" })

        let unknown = Archive(listing: listing, url: URL(filePath: "/tmp/Example.dmg"))
        #expect(unknown.dropTargets.isEmpty)
        #expect(unknown.installerExtras.isEmpty)
        #expect(unknown.entry(at: target.path)?.isHelper == false)
    }

    @Test func localizedHFSApplicationsSymlinksUseTheSameDestination() {
        let layout = DiskImageLayout.layout(of: [
            ("Vol/应用程序", false, true, nil),
            ("Vol/Tool.app/Contents/Info.plist", false, false, nil),
        ])
        #expect(layout.dropTargets == [.init(path: "Vol/应用程序", folder: "/Applications")])
    }

    @Test func aliasCandidatesAreFiniteRegularTopLevelFiles() {
        let listing = ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Applications", isFolder: false, size: 596),
            ListedEntry(path: "应用程序", isFolder: false, size: 616),
            ListedEntry(path: "Notes/Applications", isFolder: false, size: 596),
            ListedEntry(path: "Read Me.txt", isFolder: false, size: 596),
        ])
        let archive = Archive(listing: listing, url: URL(filePath: "/tmp/Example.dmg"))
        #expect(Set(DiskImageAliasLoader.candidates(in: archive).keys) == ["Applications", "应用程序"])
        let hostile = Archive(listing: ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Applications", isFolder: false, isSymlink: true, linkTarget: "relative", size: 596),
            ListedEntry(path: "应用程序", isFolder: false, size: DiskImageAliasLoader.maxAliasBytes + 1),
            ListedEntry(path: "../Applications", isFolder: false, size: 596),
        ]), url: URL(filePath: "/tmp/Example.dmg"))
        #expect(DiskImageAliasLoader.candidates(in: hostile).isEmpty)
        let ambiguous = Archive(listing: ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Applications", isFolder: false, size: 596),
            ListedEntry(path: "../Applications", isFolder: false, size: 596),
            ListedEntry(path: "Read Me.txt", isFolder: false, size: 10),
        ]), url: URL(filePath: "/tmp/Example.dmg"))
        #expect(DiskImageAliasLoader.candidates(in: ambiguous).isEmpty)
    }

    func aliasFile(to target: URL, in folder: URL) throws -> Data {
        let data = try target.bookmarkData(options: .suitableForBookmarkFile,
                                           includingResourceValuesForKeys: [.pathKey, .isDirectoryKey], relativeTo: nil)
        let alias = folder.appending(path: UUID().uuidString)
        try URL.writeBookmarkData(data, to: alias)
        return try Data(contentsOf: alias)
    }

    @Test func aliasPropertiesAreReadWithoutResolvingAnExistingTarget() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let target = folder.url.appending(path: "Gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let data = try aliasFile(to: target, in: folder.url)
        try FileManager.default.removeItem(at: target)
        #expect(DiskImageAliasLoader.cachedFolder(in: data) == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let file = folder.url.appending(path: "Document")
        try Data("ordinary content".utf8).write(to: file)
        #expect(DiskImageAliasLoader.cachedFolder(in: try aliasFile(to: file, in: folder.url)) == nil)
    }

    @Test func untrustedAndTruncatedAliasBytesDoNotBecomeInstallDestinations() throws {
        #expect(DiskImageAliasLoader.cachedFolder(in: Data("/Applications".utf8)) == nil)
        #expect(DiskImageAliasLoader.cachedFolder(in: Data("<?xml version=\"1.0\"?><plist><string>/Applications</string></plist>".utf8)) == nil)
        #expect(DiskImageAliasLoader.cachedFolder(in: Data("book0000mark0000garbage".utf8)) == nil)
        #expect(DiskImageAliasLoader.cachedFolder(in: Data(count: Int(DiskImageAliasLoader.maxAliasBytes) + 1)) == nil)
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let data = try aliasFile(to: folder.url, in: folder.url)
        #expect(DiskImageAliasLoader.cachedFolder(in: data.prefix(32)) == nil)
        for path in ["/", "relative", "/../Applications", "/Applications/..", "/Applications\0outside", String(repeating: "a", count: 4_097)] {
            #expect(!DiskImageLayout.isSafeDropFolder(path))
        }
    }

    @Test(.enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled"))
    func aliasEnrichmentRetainsSourceAndExistingCheckResults() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let target = folder.url.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let bytes = try aliasFile(to: target, in: folder.url)
        try FileManager.default.removeItem(at: target)
        // A small ZIP gives this model test the same real engine/file-reader path without mounting.
        let file = folder.url.appending(path: "Metadata.zip")
        try ZipFixture(entries: [
            .init(name: "Vol/Applications", data: bytes, mode: 0o100644),
            .file("Vol/Read Me.txt", "keep this"),
        ]).write(to: file)
        var listing = try await ArchiveEngine.shared.list(file)
        listing.type = "Dmg"
        var archive = Archive(listing: listing, url: file, name: "Renamed.dmg")
        archive.source?.password = "remembered"
        let finding = Checkup.diskImageFinding(damaged: nil)
        archive.checkup.append(finding)
        let enriched = await DiskImageAliasLoader.prepare(archive, password: nil)
        #expect(enriched.name == archive.name)
        #expect(enriched.source?.url == archive.source?.url)
        #expect(enriched.source?.storedPaths == archive.source?.storedPaths)
        #expect(enriched.source?.password == "remembered")
        #expect(enriched.checkup.contains { $0.id == finding.id })
        #expect(enriched.dropTargets == [.init(path: "Vol/Applications", folder: target.path)])
        #expect(enriched.aliasDropTargets == enriched.dropTargets)
        #expect(enriched.entry(at: "Vol/Applications")?.isHelper == true)
        #expect(enriched.children(of: "Vol").map(\.name) == ["Read Me.txt"])
        #expect(enriched.installerExtras.contains("Vol/Applications"))
        let repeated = await DiskImageAliasLoader.prepare(enriched, password: nil)
        #expect(repeated.id == enriched.id)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func namedIconCompanionsAreListedInsideTheAppAndExplicitFilesWin() throws {
        func plist(_ values: [String: String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
        let archive = Archive(listing: ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "ArcZip.app/Contents/Resources/ArcZip.icns", isFolder: false, size: 1_000),
            ListedEntry(path: "ArcZip.app/Contents/Resources/Explicit.icns", isFolder: false, size: 1_000),
        ]), url: URL(filePath: "/tmp/Example.dmg"))
        #expect(ArchivedAppIcon.iconFile(app: "ArcZip.app", plist: try plist(["CFBundleIconName": "ArcZip"]), in: archive)
                == "ArcZip.app/Contents/Resources/ArcZip.icns")
        #expect(ArchivedAppIcon.iconFile(app: "ArcZip.app", plist: try plist([
            "CFBundleIconName": "ArcZip", "CFBundleIconFile": "Explicit.icns",
        ]), in: archive) == "ArcZip.app/Contents/Resources/Explicit.icns")
        #expect(ArchivedAppIcon.iconFile(app: "ArcZip.app", plist: try plist(["CFBundleIconName": "../ArcZip"]), in: archive) == nil)
        #expect(ArchivedAppIcon.iconFile(app: "ArcZip.app", plist: try plist(["CFBundleIconName": "Missing"]), in: archive) == nil)
        #expect(ArchivedAppIcon.iconFile(app: "ArcZip.app", plist: try plist(["CFBundleIconName": "ArcZip.png"]), in: archive) == nil)
    }

    func classifiedArchive(at url: URL) -> Archive {
        var archive = Archive(listing: ArchiveListing(type: "Dmg", entries: [
            ListedEntry(path: "Vol/Applications", isFolder: false, size: 596),
            ListedEntry(path: "Vol/Docs/Keep.txt", isFolder: false, size: 5),
        ]), url: url, aliasDropTargets: [.init(path: "Vol/Applications", folder: "/Applications")])
        archive.source?.password = "remembered"
        archive.checkup.append(Checkup.diskImageFinding(damaged: nil))
        return archive
    }

    @Test func browserNameRebuildsKeepAliasClassificationAndCompletedChecks() {
        let archive = classifiedArchive(at: URL(filePath: "/tmp/Name-Rebuild.dmg"))
        let model = BrowserModel(archive: archive, installerCanvas: .ready(nil))
        defer { model.cancelTransfers() }
        model.folder = "Vol/Docs"
        model.selection = ["Vol/Docs/Keep.txt"]
        // EditSession's real rename contract sends these callbacks in this order. Keeping the
        // test at that boundary avoids touching a source file or presenting a folder-access picker.
        model.editSession.onChange?()
        model.editSession.onURLChange?(URL(filePath: "/tmp/Renamed.dmg"))
        #expect(model.archive.name == "Renamed.dmg")
        #expect(model.archive.source?.url.path == "/tmp/Renamed.dmg")
        #expect(model.archive.dropTargets == archive.dropTargets)
        #expect(model.archive.aliasDropTargets == archive.aliasDropTargets)
        #expect(model.archive.installerExtras == archive.installerExtras)
        #expect(model.archive.entry(at: "Vol/Applications")?.isHelper == true)
        #expect(model.archive.source?.password == "remembered")
        #expect(model.archive.checkup.contains { $0.title == "Disk image checks out" })
        #expect(model.folder == "Vol/Docs")
        #expect(model.selection == ["Vol/Docs/Keep.txt"])

        model.readNames(as: .utf8)
        #expect(model.archive.source?.nameEncoding == .utf8)
        #expect(model.archive.dropTargets == archive.dropTargets)
        #expect(model.archive.aliasDropTargets == archive.aliasDropTargets)
        #expect(model.level.savedArchive.aliasDropTargets == archive.aliasDropTargets)
        #expect(model.archive.source?.password == "remembered")
        #expect(model.archive.checkup.contains { $0.title == "Disk image checks out" })
        #expect(model.folder == "Vol/Docs")
    }

    @Test(.enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled"))
    func reloadingChangedBytesDiscardsOldAliasDestinationsAndChecksumResults() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.url.appending(path: "Changed.dmg")
        // The previously listed image has been replaced by an ordinary ZIP with an identically
        // named text file. Reload must trust the new container and bytes rather than cached aliases.
        try ZipFixture(entries: [.file("Vol/Applications", "ordinary text"), .file("Vol/Docs/Keep.txt", "hello")]).write(to: file)
        let model = BrowserModel(archive: classifiedArchive(at: file), installerCanvas: .ready(nil))
        defer { model.cancelTransfers() }
        model.folder = "Vol/Docs"
        model.selection = ["Vol/Docs/Keep.txt"]
        #expect(await model.reloadArchive())
        #expect(model.archive.format == .zip)
        #expect(model.archive.aliasDropTargets.isEmpty)
        #expect(model.archive.dropTargets.isEmpty)
        #expect(model.archive.installerExtras.isEmpty)
        #expect(model.archive.entry(at: "Vol/Applications")?.isHelper == false)
        #expect(!model.archive.checkup.contains { $0.title == "Disk image checks out" })
        #expect(model.folder == "Vol/Docs")
        #expect(model.selection == ["Vol/Docs/Keep.txt"])
    }

    @Test func checksumCompletionBelongsToItsSourceLevelAfterNavigatingInside() async throws {
        var archive = classifiedArchive(at: URL(filePath: "/tmp/Checksum-\(UUID().uuidString).dmg"))
        archive.checkup.removeAll { $0.title == "Disk image checks out" }
        let model = BrowserModel(archive: archive, installerCanvas: .ready(nil))
        defer { model.cancelTransfers() }
        let root = model.level
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = try #require(model.verifyDiskImage { _ in
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let inner = BrowserModel.Level(archive: Archive(name: "Nested.zip", format: .zip, files: []), entryPath: "Nested.zip")
        model.navigate(to: "", levels: [root, inner])
        release.continuation.yield(())
        release.continuation.finish()
        await task.value
        #expect(root.archive.checkup.contains { $0.title == "Disk image checks out" })
        #expect(root.savedArchive.checkup.contains { $0.title == "Disk image checks out" })
        #expect(!model.archive.checkup.contains { $0.title == "Disk image checks out" })
    }

    @Test func checksumCompletionDoesNotCertifyAReplacementArchive() async throws {
        var archive = classifiedArchive(at: URL(filePath: "/tmp/Checksum-\(UUID().uuidString).dmg"))
        archive.checkup.removeAll { $0.title == "Disk image checks out" }
        let model = BrowserModel(archive: archive, installerCanvas: .ready(nil))
        defer { model.cancelTransfers() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = try #require(model.verifyDiskImage { _ in
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        var replacement = classifiedArchive(at: try #require(archive.source?.url))
        replacement.checkup.removeAll { $0.title == "Disk image checks out" }
        model.archive = replacement
        release.continuation.yield(())
        release.continuation.finish()
        await task.value
        #expect(!model.archive.checkup.contains { $0.title == "Disk image checks out" })
    }

    func legacyStore(background: Data, alias: Data? = nil, modern: Bool = false) throws -> Data {
        var store = DSStore()
        func add(_ code: StaticString, _ value: DSStore.Value) {
            store.add(.init(filename: ".", type: .init(fourCC: .literal(code)), value: value))
        }
        var icon = Data("icv4".utf8)
        icon.append(contentsOf: [0, 108])
        icon.append(Data(count: 26))
        add("icvo", .data(icon))
        add("icvt", .uint16(14))
        add("BKGD", .data(background))
        if let alias { add("pict", .data(alias)) }
        if modern {
            store.setBackground(.color(red: 0.25, green: 0.5, blue: 0.75))
            var settings = try #require(store.iconViewSettings())
            settings.iconSize = 160
            settings.textSize = 16
            store.setIconViewSettings(settings)
        }
        try store.setIconPosition(for: "Tool.app", x: 178, y: 198)
        return try store.serialize()
    }

    @Test func legacyFinderRecordsRecoverTheAuthoredBackgroundAndSizes() throws {
        let alias = backgroundAlias(file: "dmgcanvas_bg.tiff")
        var background = Data("PctB".utf8)
        let count = UInt32(alias.count)
        background.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255), 0, 0, 0, 0])
        let layout = try #require(InstallerLayout.read(legacyStore(background: background, alias: alias)))
        #expect(layout.iconSize == 108)
        #expect(layout.textSize == 14)
        #expect(layout.background == .picture(volumePaths: ["/.background/dmgcanvas_bg.tiff"]))
        #expect(layout.positions["Tool.app"] == CGPoint(x: 178, y: 198))

        let modern = try #require(InstallerLayout.read(legacyStore(background: background, alias: alias, modern: true)))
        #expect(modern.iconSize == 160 && modern.textSize == 16)
        #expect(modern.background == .color(red: 0.25, green: 0.5, blue: 0.75))

        let truncated = try #require(InstallerLayout.read(legacyStore(background: background, alias: alias.prefix(30))))
        #expect(truncated.background == .plain)
        let malformed = try #require(InstallerLayout.read(legacyStore(background: Data("PctB".utf8))))
        #expect(malformed.background == .plain)
    }
}
