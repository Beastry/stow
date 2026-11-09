import AppKit
import CoreGraphics
import DSStore
import Foundation
import SwiftUI
import Testing
@testable import Stow

/// A version 2 Carbon Alias, as Finder writes for a background picture (#344).
func backgroundAlias(parent: String = ".background", file: String = "bg.png", posixPath: Bool = true, version: UInt8 = 2) -> Data {
    var data = Data(count: version == 2 ? 150 : 58)
    data[7] = version
    if version == 2 {
        let name = Array(file.utf8.prefix(63))
        data[50] = UInt8(name.count)
        data.replaceSubrange(51..<(51 + name.count), with: name)
    }
    func tag(_ tag: Int16, _ value: [UInt8]) {
        data.append(contentsOf: [UInt8(UInt16(bitPattern: tag) >> 8), UInt8(UInt16(bitPattern: tag) & 0xFF),
                                 UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
        data.append(contentsOf: value)
        if value.count % 2 == 1 { data.append(0) }
    }
    tag(0, Array(parent.utf8))
    let units = Array(file.utf16)
    tag(14, [UInt8(units.count >> 8), UInt8(units.count & 0xFF)] + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    if posixPath { tag(18, Array("/\(parent)/\(file)".utf8)) }
    tag(19, Array("/Volumes/Author's Mac".utf8))
    tag(-1, [])
    return data
}

@Suite("Disk image volumes")
struct DiskImageVolumeTests {
    func listing(root: String, rootEntry: ListedEntry? = nil) -> ArchiveListing {
        ArchiveListing(type: "Dmg", physicalSize: 100, entries: [rootEntry ?? ListedEntry(path: root, isFolder: true, size: 0)].compactMap { $0 } + [
            ListedEntry(path: "\(root)/.background/bg.png", isFolder: false, size: 3),
            ListedEntry(path: "\(root)/.DS_Store", isFolder: false, size: 6_148),
            ListedEntry(path: "\(root)/Applications", isFolder: false, isSymlink: true, size: 13),
            ListedEntry(path: "\(root)/Tool.app/Contents/Info.plist", isFolder: false, size: 5),
        ])
    }

    /// Volume names are often versions or domains: the dot isn't an extension (#344).
    @Test(arguments: ["PikPak-v2.7.1.2480", "Layout Tool v2.7.1 测试", "app.example.com", "Tool 1.0", "Backups.zip"])
    func dottedNamesAreVolumes(name: String) {
        let archive = Archive(listing: listing(root: name), url: URL(filePath: "/tmp/Tool.dmg"))
        #expect(archive.volumeRoot == name)
        #expect(archive.dropTargets.map(\.folder) == ["/Applications"])
        #expect(archive.children(of: name).map(\.name) == ["Tool.app"])
        #expect(BrowserModel.suggestedSelection(in: archive) == "\(name)/Tool.app")
        #expect(archive.presentationFiles["\(name)/.DS_Store"] == 6_148)
        #expect(archive.presentationFiles["\(name)/.background/bg.png"] == 3)
    }

    /// An APFS image lists its contents at the top: a sole package there is content, not a volume.
    @Test(arguments: ["Tool.app", "Setup.pkg", "Setup.mpkg", "Notes.rtfd", "Plug.bundle"])
    func topLevelPackagesAreContent(name: String) {
        let listing = ArchiveListing(type: "Dmg", physicalSize: 100, entries: [
            ListedEntry(path: name, isFolder: true, size: 0),
            ListedEntry(path: "\(name)/Contents/Info.plist", isFolder: false, size: 5),
        ])
        let archive = Archive(listing: listing, url: URL(filePath: "/tmp/Tool.dmg"))
        #expect(archive.volumeRoot == "")
        #expect(archive.children(of: "").map(\.name) == [name])
    }

    @Test func aLinkOrFileAtTheTopIsNotAVolume() {
        let link = Archive(listing: listing(root: "Vol", rootEntry: ListedEntry(path: "Vol", isFolder: false, isSymlink: true, size: 4)),
                           url: URL(filePath: "/tmp/Tool.dmg"))
        #expect(link.volumeRoot == "")
        let file = Archive(listing: listing(root: "Vol", rootEntry: ListedEntry(path: "Vol", isFolder: false, size: 4)),
                           url: URL(filePath: "/tmp/Tool.dmg"))
        #expect(file.volumeRoot == "")
    }
}

@Suite("Installer layout")
struct InstallerLayoutTests {
    func store(_ build: (inout DSStore) throws -> Void) throws -> Data {
        var store = DSStore()
        try build(&store)
        return try store.serialize()
    }

    @Test func readsTheAuthorsWindow() throws {
        let data = try store { store in
            store.setViewStyle(.iconView)
            try store.setWindowBounds(top: 100, left: 100, bottom: 502, right: 700)
            store.setBackground(.picture(aliasData: backgroundAlias(file: "dmg-bg@2x.png")))
            var settings = try #require(store.iconViewSettings())
            settings.iconSize = 128
            settings.textSize = 12
            store.setIconViewSettings(settings)
            try store.setIconPosition(for: "PikPak.app", x: 148, y: 160)
            try store.setIconPosition(for: "Applications", x: 452, y: 160)
        }
        let layout = try #require(InstallerLayout.read(data))
        #expect(layout.iconSize == 128 && layout.textSize == 12)
        #expect(layout.positions == ["PikPak.app": CGPoint(x: 148, y: 160), "Applications": CGPoint(x: 452, y: 160)])
        #expect(layout.windowSize == CGSize(width: 600, height: 402 - InstallerLayout.titleBarHeight))
        #expect(layout.background == .picture(volumePaths: ["/.background/dmg-bg@2x.png"]))
        let size = layout.canvasSize(background: CGSize(width: 600, height: 350), placed: ["PikPak.app", "Applications"])
        #expect(size == CGSize(width: 600, height: 350))
    }

    @Test func dropsWhatDoesNotHoldUp() throws {
        let data = try store { store in
            store.setBackground(.color(red: 2, green: -1, blue: 0.5))
            var settings = try #require(store.iconViewSettings())
            settings.iconSize = 4_000
            settings.textSize = 200
            store.setIconViewSettings(settings)
            try store.setIconPosition(for: "Far.app", x: 60_000, y: 10)
            try store.setIconPosition(for: "Fine.app", x: 10, y: 20)
        }
        let layout = try #require(InstallerLayout.read(data))
        #expect(layout.positions == ["Fine.app": CGPoint(x: 10, y: 20)])
        #expect(layout.iconSize == 64 && layout.textSize == 12)
        #expect(layout.background == .color(red: 1, green: 0, blue: 0.5))
        // An item placed beyond the window grows the canvas to hold it.
        #expect(layout.canvasSize(background: nil, placed: ["Fine.app"]).width >= 128)
    }

    @Test func nothingUsableMeansNoLayout() throws {
        #expect(InstallerLayout.read(Data()) == nil)
        #expect(InstallerLayout.read(Data("not a store".utf8)) == nil)
        let data = try store { try $0.setIconPosition(for: "A.app", x: 10, y: 10) }
        #expect(InstallerLayout.read(data.prefix(data.count / 2)) == nil)
        #expect(InstallerLayout.read(Data(count: InstallerLayout.maxStoreBytes + 1)) == nil)
        let empty = try store { $0.setViewStyle(.listView) }
        #expect(InstallerLayout.read(empty) == nil)
    }

    @Test func flippedBytesNeverCrash() throws {
        let data = try store { store in
            store.setBackground(.picture(aliasData: backgroundAlias()))
            try store.setIconPosition(for: "A.app", x: 10, y: 10)
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var copy = data
            for _ in 0..<4 { copy[Int.random(in: 0..<copy.count, using: &generator)] = .random(in: 0...255, using: &generator) }
            _ = InstallerLayout.read(copy)
        }
    }

    @Test func aliasesNameAFileInTheVolumeOnly() {
        #expect(CarbonAlias.volumePaths(in: backgroundAlias()) == ["/.background/bg.png"])
        #expect(CarbonAlias.volumePaths(in: backgroundAlias(posixPath: false)) == ["/.background/bg.png", "/bg.png"])
        #expect(CarbonAlias.volumePaths(in: backgroundAlias(version: 3)) == ["/.background/bg.png"])
        #expect(CarbonAlias.volumePaths(in: backgroundAlias(file: "a/b.png", posixPath: false)).isEmpty)
        #expect(CarbonAlias.volumePaths(in: Data([0, 0, 0, 0, 0, 10, 0, 9])).isEmpty)
        // Cut off inside the extras: only the fixed part's file name is left.
        #expect(CarbonAlias.volumePaths(in: backgroundAlias().prefix(160)) == ["/bg.png"])

        #expect(InstallerLayout.archivePath("/.background/bg.png", volumeRoot: "Vol 1.2") == "Vol 1.2/.background/bg.png")
        #expect(InstallerLayout.archivePath("/.background/bg.png", volumeRoot: "") == ".background/bg.png")
        #expect(InstallerLayout.archivePath("/../Users/me/bg.png", volumeRoot: "Vol") == nil)
        #expect(InstallerLayout.archivePath("/", volumeRoot: "Vol") == nil)
    }

    @Test func retinaArtworkIsDrawnAtItsPoints() {
        #expect(InstallerCanvasLoader.backgroundScale(name: "dmg-bg@2x.png", pixelWidth: 1_200, source: nil, window: nil) == 2)
        #expect(InstallerCanvasLoader.backgroundScale(name: "bg@3x.png", pixelWidth: 1_800, source: nil, window: nil) == 3)
        #expect(InstallerCanvasLoader.backgroundScale(name: "bg.png", pixelWidth: 1_200, source: nil, window: CGSize(width: 600, height: 374)) == 2)
        #expect(InstallerCanvasLoader.backgroundScale(name: "bg.png", pixelWidth: 600, source: nil, window: CGSize(width: 600, height: 374)) == 1)
    }

    @Test func declaredIconsStayInsideTheApp() throws {
        func plist(_ icon: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIconFile": icon], format: .xml, options: 0)
        }
        #expect(ArchivedAppIcon.iconPath(app: "V/A.app", plist: try plist("electron.icns")) == "V/A.app/Contents/Resources/electron.icns")
        #expect(ArchivedAppIcon.iconPath(app: "V/A.app", plist: try plist("tool")) == "V/A.app/Contents/Resources/tool.icns")
        #expect(ArchivedAppIcon.iconPath(app: "V/A.app", plist: try plist("../../x.icns")) == nil)
        #expect(ArchivedAppIcon.iconPath(app: "V/A.app", plist: Data("junk".utf8)) == nil)
    }

    @Test func appIconsAreDecodedOnlyUpToTheirLargestSize() async throws {
        func png(_ side: Int) throws -> Data {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        #expect(await ArchivedAppIcon.decode(try png(64)) != nil)
        #expect(await ArchivedAppIcon.decode(try png(4_096)) == nil)
        #expect(await ArchivedAppIcon.decode(Data("not an icon".utf8)) == nil)
    }
}

/// The real thing through the sandboxed engine: Tests/Fixtures/Fixture-Layout.dmg (see
/// scripts/make-fixtures.sh) has a dotted, non-ASCII volume name, 2x artwork, positions, a
/// declared icon, an Applications shortcut and an unplaced file.
@Suite("Installer canvas", .enabled(if: SevenZip.bundled() != nil, "7zz isn't bundled — run scripts/fetch-7zip.sh"))
@MainActor
struct InstallerCanvasTests {
    static let volume = "Layout Tool v2.7.1 测试"

    func open() async throws -> (Archive, TemporaryFolder) {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "Fixture-Layout.dmg")
        try FileManager.default.copyItem(at: try InstallEngineTests.fixture("Fixture-Layout.dmg"), to: image)
        return (Archive(listing: try await ArchiveEngine.shared.list(image), url: image), folder)
    }

    @Test func readsTheAuthoredWindowWithoutExtractingTheApp() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        #expect(archive.volumeRoot == Self.volume)
        #expect(archive.children(of: Self.volume).map(\.name) == ["Layout Tool.app", "Read Me.txt"])
        #expect(archive.presentationFiles.keys.contains("\(Self.volume)/.DS_Store"))

        let canvas = try #require(await InstallerCanvasLoader.load(archive, password: nil))
        #expect(canvas.archiveID == archive.id)
        #expect(canvas.layout.iconSize == 96)
        #expect(canvas.layout.positions["Layout Tool.app"] == CGPoint(x: 100, y: 120))
        #expect(canvas.layout.positions["Applications"] == CGPoint(x: 300, y: 120))
        #expect(canvas.layout.positions["Read Me.txt"] == nil)
        #expect(canvas.backgroundSize == CGSize(width: 400, height: 250))
        #expect(canvas.icons["\(Self.volume)/Layout Tool.app"] != nil)
        // Names sit on the light plates drawn into the dark art.
        #expect(!canvas.labelIsLight("Applications") && !canvas.labelIsLight("Layout Tool.app"))
    }

    @Test func opensOnTheCanvasAndDropsInstallOnlyTheApp() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let model = BrowserModel(archive: archive)
        model.viewMode = .list
        // Rebuilt so the window "opened" in List.
        let listModel = BrowserModel(archive: archive)
        for _ in 0..<200 where model.installerCanvas == nil || listModel.installerCanvas == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(listModel.viewMode == .grid)
        #expect(listModel.showsInstallerCanvas)
        // Someone who picked List before it arrived keeps List.
        #expect(model.viewMode == .list && !model.showsInstallerCanvas)

        let target = try #require(archive.dropTargets.first)
        let app = try #require(archive.entry(at: "\(Self.volume)/Layout Tool.app"))
        let readMe = try #require(archive.entry(at: "\(Self.volume)/Read Me.txt"))
        #expect(listModel.installStep(for: [app], onto: target) == .moveToApplications)
        #expect(listModel.installStep(for: [readMe], onto: target) == nil)
        #expect(listModel.installStep(for: [app, readMe], onto: target) == nil)
        // Selecting the app installs nothing.
        listModel.select([app.id])
        #expect(listModel.activity == nil)

        listModel.query = "Read"
        #expect(!listModel.showsInstallerCanvas)
    }

    @Test func anOpeningWindowArrivesAsTheAuthorsWindowWithTheAppsIcon() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let start = await InstallerCanvasLoader.prepare(archive, password: nil)
        guard case .ready(let canvas?) = start else {
            Issue.record("The layout wasn't read while opening")
            return
        }
        let model = BrowserModel(archive: archive, installerCanvas: start)
        // The very first frame: no plain icons that turn into the canvas a moment later.
        #expect(model.installerCanvas?.archiveID == canvas.archiveID)
        #expect(model.showsInstallerCanvas)
        let app = try #require(archive.entry(at: "\(Self.volume)/Layout Tool.app"))
        // The grid, list and Details reuse the icon the canvas read.
        #expect(model.previews.cachedAppIcon(for: app, in: archive) != nil)
    }

    @Test func aSlowLayoutArrivesAfterTheFilesShow() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let pending = Task { await InstallerCanvasLoader.load(archive, password: nil) }
        let model = BrowserModel(archive: archive, installerCanvas: .pending(pending))
        for _ in 0..<200 where model.installerCanvas == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.showsInstallerCanvas)
    }

    @Test func archivesWithoutALayoutOpenAtOnce() async throws {
        let archive = try Archive(listing: await ArchiveEngine.shared.list(InstallEngineTests.fixture("Fixture-HFS.dmg")),
                                  url: InstallEngineTests.fixture("Fixture-HFS.dmg"))
        guard case .ready(nil) = await InstallerCanvasLoader.prepare(archive, password: nil, limit: .zero) else {
            Issue.record("An image without a layout waited for one")
            return
        }
    }

    @Test func appsShowTheirOwnIconAnywhereInAnArchive() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let previews = PreviewService()
        let app = try #require(archive.entry(at: "\(Self.volume)/Layout Tool.app"))
        let readMe = try #require(archive.entry(at: "\(Self.volume)/Read Me.txt"))
        let icon = try #require(await previews.appIcon(for: app, in: archive))
        #expect(icon.representations.allSatisfy { $0.pixelsWide <= ArchivedAppIcon.maxIconPixels })
        #expect(previews.cachedAppIcon(for: app, in: archive) === icon)
        #expect(await previews.appIcon(for: readMe, in: archive) == nil)
    }

    @Test func aClosedWindowNeverTakesTheCanvas() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let model = BrowserModel(archive: archive)
        model.cancelTransfers()
        try await Task.sleep(for: .seconds(3))
        #expect(model.installerCanvas == nil)
    }

    @Test func canvasSelectionAndExtractionUseOnlyDisplayedFiles() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let model = BrowserModel(archive: archive, installerCanvas: await InstallerCanvasLoader.prepare(archive, password: nil))
        model.showHelperItems = true
        model.gridColumns = 1
        #expect(model.showsInstallerCanvas)
        let expected = Set(archive.children(of: archive.volumeRoot).map(\.id))
        #expect(!expected.isEmpty)
        #expect(Set(model.visibleEntries.map(\.id)) == expected)

        model.select([])
        var reached = Set<ArchiveEntry.ID>()
        for _ in 0..<expected.count {
            model.move(.down)
            reached.formUnion(model.selection)
        }
        #expect(reached == expected)

        let first = try #require(model.visibleEntries.first)
        let last = try #require(model.visibleEntries.last)
        model.select([first.id])
        model.click(last, modifiers: .shift)
        #expect(model.selection == expected)
        model.select([first.id])
        model.move(.down, extending: true)
        #expect(model.selection == expected)
        model.select([first.id])
        model.typeSelect(".")
        #expect(model.selection == [first.id])

        model.selectAll()
        #expect(model.selection == expected)
        let out = folder.url.appending(path: "Canvas Selection", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try await Extraction.run(archive, selection: model.selectedEntries, to: out) { _ in }
        let names = TemporaryFolder.contents(of: out)
        #expect(names.contains("Layout Tool.app") && names.contains("Read Me.txt"))
        #expect(!names.contains { $0.contains(".background") || $0.contains(".DS_Store") || $0 == "Applications" })
    }

    @Test func returningToCanvasDropsHelperSelectionWithoutChangingThePreference() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let model = BrowserModel(archive: archive, installerCanvas: await InstallerCanvasLoader.prepare(archive, password: nil))
        model.showHelperItems = true
        let helper = try #require(archive.entry(at: "\(Self.volume)/.DS_Store"))
        let app = try #require(archive.installable)
        for mode in [BrowserModel.ViewMode.list, .columns] {
            model.viewMode = mode
            #expect(model.visibleEntries.contains { $0.id == helper.id })
            model.select([helper.id, app.id])
            model.viewMode = .grid
            #expect(model.showsInstallerCanvas && model.showHelperItems)
            #expect(model.selection == [app.id])
            #expect(model.cursor == app.id && model.anchor == app.id)
            #expect(!model.visibleEntries.contains { $0.isHelper })
        }
        model.viewMode = .list
        model.select([helper.id])
        model.viewMode = .grid
        #expect(model.selection.isEmpty && model.cursor == nil && model.anchor == nil)
    }

    @Test func aLateCanvasRemovesSelectionsItDoesNotDisplay() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let canvas = try #require(await InstallerCanvasLoader.load(archive, password: nil))
        let pending = Task<InstallerCanvas?, Never> { canvas }
        let model = BrowserModel(archive: archive, installerCanvas: .pending(pending))
        model.viewMode = .grid
        model.showHelperItems = true
        let helper = try #require(archive.entry(at: "\(Self.volume)/.background"))
        model.select([helper.id])
        #expect(model.installerCanvas == nil)
        for _ in 0..<200 where model.installerCanvas == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.showsInstallerCanvas)
        #expect(model.selection.isEmpty)
        #expect(!model.visibleEntries.contains { $0.isHelper })
    }

    @Test func theImagesWindowDressingIsListedDimmed() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let helpers = archive.children(of: Self.volume, includingHelpers: true).filter(\.isHelper).map(\.name)
        #expect(Set(helpers).isSuperset(of: [".background", ".DS_Store", "Applications"]))
        let model = BrowserModel(archive: archive)
        // Shown by default in an image, dimmed; never the archive's one app.
        #expect(model.showHelperItems)
        #expect(model.visibleEntries.contains { $0.name == ".background" && $0.isHelper })
        // The switch beside the path counts them either way.
        let count = model.helperItemCount
        #expect(count >= 3)
        model.showHelperItems = false
        #expect(!model.visibleEntries.contains(where: \.isHelper) && model.helperItemCount == count)
        #expect(archive.installable?.name == "Layout Tool.app")
        let background = try #require(archive.entry(at: "\(Self.volume)/.background"))
        let target = try #require(archive.dropTargets.first)
        #expect(model.installStep(for: [background], onto: target) == nil)
    }

    @Test func theLastChoiceIsHowTheNextImageOpens() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let suite = "StowTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        #expect(SettingsKeys.showsDiskImageHelpers(in: store))
        let model = BrowserModel(archive: archive)
        model.setShowsHelperItems(false, rememberingIn: store)
        #expect(!model.showHelperItems && !SettingsKeys.showsDiskImageHelpers(in: store))
        model.setShowsHelperItems(true, rememberingIn: store)
        #expect(SettingsKeys.showsDiskImageHelpers(in: store))
    }

    @Test func aChosenLayoutFileIsExtracted() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let out = folder.url.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let background = try #require(archive.entry(at: "\(Self.volume)/.background"))
        _ = try await Extraction.run(archive, selection: [background], to: out) { _ in }
        #expect(TemporaryFolder.contents(of: out).contains { $0.hasSuffix("bg@2x.png") })
    }

    @Test func extractAllLeavesThePresentationBehind() async throws {
        let (archive, folder) = try await open()
        defer { folder.cleanUp() }
        let out = folder.url.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try await Extraction.run(archive, selection: nil, to: out) { _ in }
        let names = TemporaryFolder.contents(of: out).filter { !$0.contains(".app/") }
        #expect(!names.contains { $0.contains(".background") || $0.contains(".DS_Store") || $0.hasSuffix("Applications") })
        #expect(names.contains { $0.hasSuffix("Layout Tool.app") } && names.contains { $0.hasSuffix("Read Me.txt") })
    }
}

@Suite("Installer canvas artwork geometry")
@MainActor
struct InstallerCanvasArtworkTests {
    @Test(arguments: [1.0, 0.5])
    func extendingCanvasDoesNotMoveArtworkLandmarks(scale: Double) throws {
        // A green name plate at x=100 in red artwork. Another authored icon beyond the picture
        // grows the canvas, but must not move the plate or spread the red artwork into the margin.
        let context = try #require(CGContext(data: nil, width: 400, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 250))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 90, y: 0, width: 20, height: 250))
        let backgroundSize = CGSize(width: 400, height: 250)
        let image = NSImage(cgImage: try #require(context.makeImage()), size: backgroundSize)
        var layout = InstallerLayout()
        layout.positions = ["Tool.app": CGPoint(x: 100, y: 100), "Read Me.txt": CGPoint(x: 600, y: 300)]
        let canvas = InstallerCanvas(archiveID: UUID(), layout: layout, background: image,
                                     backgroundSize: backgroundSize, icons: [:], darkUnderLabel: [])
        let extent = layout.canvasSize(background: backgroundSize, placed: layout.positions.keys)
        #expect(extent.width > backgroundSize.width && extent.height > backgroundSize.height)
        let renderer = ImageRenderer(content: InstallerCanvasBackground(canvas: canvas, scale: scale)
            .frame(width: extent.width * scale, height: extent.height * scale))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let plate = try #require(bitmap.colorAt(x: Int(100 * scale), y: Int(125 * scale))?.usingColorSpace(.deviceRGB))
        #expect(plate.greenComponent > 0.9 && plate.redComponent < 0.1)
        let margin = try #require(bitmap.colorAt(x: Int(450 * scale), y: Int(125 * scale))?.usingColorSpace(.deviceRGB))
        #expect(margin.redComponent > 0.9 && margin.greenComponent > 0.9 && margin.blueComponent > 0.9)
    }
}

@Suite("Archive arrival")
@MainActor
struct ArchiveArrivalTests {
    @Test func aQuickOpenJustShowsTheFiles() {
        let arrival = ArchiveArrival(afterWait: false)
        #expect(arrival.showsFiles && !arrival.showsCard)
    }

    @Test func aWaitedOpenHandsOverFromTheCard() async {
        let arrival = ArchiveArrival(afterWait: true)
        #expect(arrival.showsCard && !arrival.showsFiles)
        await arrival.play(reduceMotion: false)
        #expect(arrival.showsFiles && !arrival.showsCard)
    }
}
