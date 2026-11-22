import AppKit
import Testing
@testable import Stow

@Suite("Thumbnail request lifetime")
@MainActor
struct ThumbnailLoadTests {
    @Test func aStalledGeneratorStopsAtTheDeadline() async {
        var cancelled = 0
        let load = ThumbnailLoad(generate: { _ in }, cancel: { cancelled += 1 })
        let start = ContinuousClock.now
        let image = await load.image(timeout: .milliseconds(30))
        #expect(image == nil)
        #expect(cancelled == 1)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellationFinishesWithoutWaitingForTheGenerator() async {
        var callback: (@Sendable (NSImage?) -> Void)?
        var cancelled = 0
        let load = ThumbnailLoad(generate: { callback = $0 }, cancel: { cancelled += 1 })
        let task = Task { await load.image(timeout: .seconds(30)) }
        while callback == nil { await Task.yield() }
        task.cancel()
        #expect(await task.value == nil)
        #expect(cancelled == 1)
        // A provider can finish after cancellation; the continuation must not resume twice.
        callback?(NSImage(size: NSSize(width: 1, height: 1)))
        await Task.yield()
        #expect(cancelled == 1)
    }

    @Test func aCompletedRequestKeepsItsImage() async {
        let expected = NSImage(size: NSSize(width: 1, height: 1))
        var cancelled = 0
        let load = ThumbnailLoad(generate: { $0(expected) }, cancel: { cancelled += 1 })
        #expect(await load.image() === expected)
        #expect(cancelled == 0)
    }

    @Test func cancellationBeforeStartingDoesNotLaunchTheGenerator() async {
        var generated = false
        let load = ThumbnailLoad(generate: { _ in generated = true }, cancel: {})
        let task = Task { await load.image() }
        task.cancel()
        #expect(await task.value == nil)
        #expect(!generated)
    }
}

@Suite("Quick Look preview")
struct QuickLookPreviewTests {
    private func archive(_ paths: [(String, Int64)], checkup: [CheckupFinding] = []) -> Archive {
        let files = paths.map {
            ArchiveEntry(path: $0.0, isFolder: false, size: $0.1, packedSize: $0.1 / 2, modified: .now)
        }
        return Archive(name: "t.zip", format: .zip, files: files, checkup: checkup)
    }

    @Test func rowsAreDepthFirstFoldersFirst() {
        let model = ArchivePreviewModel(archive: archive([
            ("b.txt", 1), ("Docs/z.txt", 2), ("Docs/Sub/a.txt", 3), ("a.txt", 4),
        ]))
        #expect(model.visible(expanded: []).rows.map(\.id) == ["Docs", "a.txt", "b.txt"])
        let visible = model.visible(expanded: ["Docs", "Docs/Sub"])
        #expect(visible.rows.map(\.id) == ["Docs", "Docs/Sub", "Docs/Sub/a.txt", "Docs/z.txt", "a.txt", "b.txt"])
        #expect(visible.rows.map(\.depth) == [0, 1, 2, 1, 0, 0])
        #expect(model.fileCount == 4)
        #expect(model.folderCount == 2)
        #expect(visible.hiddenRowCount == 0)
    }

    @Test func hugeArchivesAreCapped() {
        let model = ArchivePreviewModel(archive: archive((0..<50).map { ("f\($0).txt", 1) }), rowLimit: 10)
        #expect(model.visible(expanded: []).rows.count == 10)
        #expect(model.visible(expanded: []).hiddenRowCount == 40)
    }

    @Test func collapsingRestoresOtherRootsAtTheBudgetBoundary() {
        let archive = archive([("A/B/C/one", 1), ("A/B/C/two", 1), ("z.txt", 1)])
        let model = ArchivePreviewModel(archive: archive, rowLimit: 2)
        let open = model.visible(expanded: ["A", "A/B", "A/B/C"])
        #expect(open.rows.map(\.id) == ["A", "A/B"])
        #expect(open.hiddenRowCount == 4)
        let closed = model.visible(expanded: ["A/B", "A/B/C"])
        #expect(closed.rows.map(\.id) == ["A", "z.txt"])
        #expect(closed.hiddenRowCount == 0)
    }

    @Test func headlinePrefersCautionThenHandled() {
        let fine = CheckupFinding(severity: .fine, title: "fine", detail: "")
        let handled = CheckupFinding(severity: .handled, title: "handled", detail: "")
        let caution = CheckupFinding(severity: .caution, title: "caution", detail: "")
        #expect(ArchivePreviewModel.headline(of: [fine, handled, caution])?.title == "caution")
        #expect(ArchivePreviewModel.headline(of: [fine, handled])?.title == "handled")
        #expect(ArchivePreviewModel.headline(of: []) == nil)
        #expect(ArchivePreviewModel.headline(of: [fine]) == nil)
    }

    @Test func packedSummaryDoesNotClaimSavingsWhenTheArchiveGrew() {
        #expect(ArchivePreviewModel.packedSummary(packed: 120, total: 100) == "120 bytes packed")
        #expect(ArchivePreviewModel.packedSummary(packed: 100, total: 100) == "100 bytes packed")
        #expect(ArchivePreviewModel.packedSummary(packed: 50, total: 100) == "50 bytes packed · 50% smaller")
    }

    @Test func slowListingFallsBackInTime() async throws {
        let start = ContinuousClock.now
        let content = try await ArchivePreviewLoader.load(URL(filePath: "/nonexistent/big.tar.xz"), timeout: .milliseconds(100)) { _ in
            try await Task.sleep(for: .seconds(30))
            throw EngineError(.failed)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        guard case .fallback(let fallback) = content else { Issue.record("expected a fallback"); return }
        #expect(fallback.reason == .tooSlow)
        #expect(fallback.format == .tarXz)
    }

    @Test func switchingArchivesReleasesAStalledPreviewAtCancellation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        // The old provider ignores cancellation until its external operation delivers a reply.
        let provider = Task {
            for await _ in release.stream { break }
            return ArchiveListing(type: "zip", entries: [.init(path: "old.txt", isFolder: false, size: 7)])
        }
        defer { release.continuation.finish() }
        let old = Task {
            try await ArchivePreviewLoader.load(URL(filePath: "/old.zip"), timeout: .seconds(4)) { _ in
                started.continuation.finish()
                return await provider.value
            }
        }
        for await _ in started.stream {}
        let start = ContinuousClock.now
        old.cancel()

        let next = try await ArchivePreviewLoader.load(URL(filePath: "/next.zip")) { _ in
            ArchiveListing(type: "zip", entries: [.init(path: "Empty", isFolder: true, size: 0)])
        }
        guard case .listed(let model) = next else { Issue.record("Expected the new archive"); return }
        let rows = model.visible(expanded: ["Empty"]).rows
        #expect(rows.map(\.id) == ["Empty"])
        #expect(rows.first?.isFolder == true && rows.first?.hasChildren == false)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        release.continuation.finish()
        _ = await provider.value
    }

    @Test func encryptedNamesFallBack() async throws {
        let content = try await ArchivePreviewLoader.load(URL(filePath: "/x/secret.7z")) { _ in
            throw EngineError(.passwordRequired)
        }
        guard case .fallback(let fallback) = content else { Issue.record("expected a fallback"); return }
        #expect(fallback.reason == .encrypted)
    }

    @Test func realArchiveListsThroughTheEngine() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let zip = folder.url.appending(path: "t.zip")
        try ZipFixture(entries: [.file("Docs/a.txt", "hi"), .file("b.txt", "yo")]).write(to: zip)
        let content = try await ArchivePreviewLoader.load(zip) { try await ArchiveEngine.shared.list($0) }
        guard case .listed(let model) = content else { Issue.record("expected a listing, got \(content)"); return }
        #expect(model.visible(expanded: ["Docs"]).rows.map(\.id) == ["Docs", "Docs/a.txt", "b.txt"])
        #expect(model.headline == nil)
    }

    @Test(arguments: [("logs.tar.xz", "logs.tar"), ("a.tgz", "a.tar"), ("notes.txt.gz", "notes.txt"), ("x.bz2", "x")])
    func compressedStreamsGetTheirInnerName(archive: String, inner: String) {
        #expect(SevenZip.innerName(of: archive) == inner)
    }

    @Test func unnamedStreamIsListedUnderItsInnerName() throws {
        let output = """
        --
        Path = logs.tar.xz
        Type = xz
        Physical Size = 552

        ----------
        Size = 12288
        Packed Size = 552

        """
        let listing = try #require(SevenZip.parseListing(output))
        #expect(listing.entries.map(\.path) == ["logs.tar"])
        #expect(listing.entries.first?.size == 12288)
    }
}

@Suite("Registered file types")
struct RegisteredTypesTests {
    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private var app: Bundle {
        // The test host is Stow.app.
        Bundle.main
    }

    @Test func documentTypesCoverTheCatalog() throws {
        let types = try #require(app.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(declared == Set(ArchiveTypes.all.map(\.id)))
        let alternate = types.first { $0["LSHandlerRank"] as? String == "Alternate" }?["LSItemContentTypes"] as? [String]
        #expect(Set(alternate ?? []) == Set(ArchiveTypes.all.filter { !$0.suggested }.map(\.id)))
    }

    @Test func ownTypesAreImportedWithTheirExtensions() throws {
        let imported = try #require(app.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]])
        var byID: [String: [String]] = [:]
        for declaration in imported {
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            byID[declaration["UTTypeIdentifier"] as? String ?? ""] = tags?["public.filename-extension"] as? [String]
        }
        for type in ArchiveTypes.all where !type.isSystemDeclared {
            #expect(byID[type.id] == type.extensions, "\(type.id)")
        }
        #expect(Set(byID.keys) == Set(ArchiveTypes.all.filter { !$0.isSystemDeclared }.map(\.id)))
    }

    @Test func quickLookPreviewsEveryType() throws {
        let appex = try #require(app.builtInPlugInsURL?.appending(path: "StowQuickLook.appex/Contents/Info.plist"))
        let info = try plist(appex)
        let attributes = (info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        let supported = attributes?["QLSupportedContentTypes"] as? [String] ?? []
        #expect(Set(supported) == Set(ArchiveTypes.all.map(\.id)))
    }

    @Test func everyExtensionResolvesToItsType() {
        for type in ArchiveTypes.all {
            for ext in type.extensions {
                #expect(ArchiveTypes.type(forFileName: "x.\(ext)")?.id == type.id, "\(ext)")
            }
        }
        #expect(ArchiveTypes.type(forFileName: "logs.tar.xz")?.id == "org.tukaani.xz-archive")
    }
}

/// Quick Look has no asset catalog, so it writes the accent out. It must stay the app's AccentColor,
/// or its white button words fall below 4.5 : 1 in dark mode again.
@Suite("Quick Look accent")
struct QuickLookAccentTests {
    private func srgb(_ color: NSColor, in name: NSAppearance.Name) throws -> [Int] {
        let appearance = try #require(NSAppearance(named: name))
        var rgb: [Int] = []
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
            }
        }
        return rgb
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func matchesTheAppAccent(_ name: NSAppearance.Name) throws {
        let app = try #require(NSColor(named: "AccentColor", bundle: .main))
        #expect(try srgb(ArchivePreview.amberColor(for: name), in: name) == srgb(app, in: name))
    }

    @Test func increaseContrastDeepensInBothLooks() {
        let deep = ArchivePreview.amberColor(for: .accessibilityHighContrastAqua)
        #expect(ArchivePreview.amberColor(for: .accessibilityHighContrastDarkAqua) == deep)
        #expect(deep.usingColorSpace(.sRGB)?.redComponent ?? 0 < ArchivePreview.amberColor(for: .darkAqua).redComponent)
    }
}
