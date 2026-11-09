#if STOW_DMG_CORPUS
import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Stow

/// Opt-in, local compatibility evidence for third-party images. The shell wrapper stages inputs
/// in the test host's sandbox and supplies independently captured expectations. Nothing here
/// mounts an image, launches a payload, installs an app, or writes to /Applications.
@Suite("Real DMG corpus")
@MainActor
struct DMGCorpusTests {
    @Test(.timeLimit(.minutes(60)))
    func testRealImagesThroughSandboxedEngine() async throws {
        let manifestPath = try #require(ProcessInfo.processInfo.environment["STOW_DMG_CORPUS"],
                                        "Run scripts/check-dmg-corpus.sh to stage the corpus")
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.schemaVersion == 1)
        #expect(!manifest.images.isEmpty)
        let reports = URL(fileURLWithPath: manifest.reportDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var results: [ImageResult] = []

        // Sequential by design: each image makes several real XPC extraction trips. Keep disk,
        // process and decoder pressure bounded, and remove each staged input when finished.
        for image in manifest.images {
            let began = Date()
            var result = ImageResult(id: image.id, filename: image.filename)
            let input = URL(fileURLWithPath: image.stagedPath)
            let stage = URL(fileURLWithPath: manifest.stageDirectory, isDirectory: true).standardizedFileURL.path
            guard input.standardizedFileURL.path.hasPrefix(stage + "/"), input.pathExtension.lowercased() == "dmg" else {
                throw CorpusError.invalidStagedPath(image.stagedPath)
            }
            do {
                try await inspect(image, input: input, result: &result)
            } catch {
                result.failures.append("Operation failed: \(error)")
            }
            result.durationSeconds = Date().timeIntervalSince(began)
            results.append(result)
            try write(result, to: reports.appendingPathComponent(image.id + ".json"))
            try write(results, to: reports.appendingPathComponent("results.json"))
            try report(results, manifest: manifest).write(to: reports.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: input)
            for failure in result.failures { Issue.record("\(image.filename): \(failure)") }
            print("DMG corpus: \(image.filename): \(result.failures.isEmpty ? "PASS" : "FAIL"), \(String(format: "%.2f", result.durationSeconds)) s")
        }
        #expect(results.count == manifest.images.count)
    }

    private func inspect(_ expected: ImageExpectation, input: URL, result: inout ImageResult) async throws {
        let listing = try await ArchiveEngine.shared.list(input)
        let archive = await DiskImageAliasLoader.prepare(Archive(listing: listing, url: input), password: nil)
        result.listedEntries = listing.entries.count
        result.volumeRoot = archive.volumeRoot
        result.visibleRootNames = archive.children(of: archive.volumeRoot).map(\.name).sorted()
        result.presentationFiles = archive.presentationFiles
        result.dropTargetPaths = archive.dropTargets.map(\.path).sorted()
        result.dropTargets = Dictionary(archive.dropTargets.map { ($0.path, $0.folder) }, uniquingKeysWith: { first, _ in first })
        result.installablePath = archive.installable?.path
        result.checkup = archive.checkup.map { String(describing: $0) }
        check(!listing.entries.isEmpty, "XPC returned an empty listing", result: &result)
        check(archive.format == .dmg, "Archive model did not identify a disk image", result: &result)
        check(archive.volumeRoot == expected.expectedRoot, "Volume root: expected \(expected.expectedRoot.debugDescription), got \(archive.volumeRoot.debugDescription)", result: &result)
        check(archive.installable?.path == expected.expectedInstallablePath, "Unexpected top-level app/package", result: &result)
        check(result.dropTargets == expected.expectedDropTargets, "Install drop targets differ: expected \(expected.expectedDropTargets), got \(result.dropTargets)", result: &result)
        for path in expected.expectedDropTargets.keys {
            check(archive.entry(at: path)?.isHelper == true, "Install target was not classified as a helper: \(path)", result: &result)
            check(!archive.children(of: archive.volumeRoot).contains { $0.path == path },
                  "Install target remained ordinary browsable content: \(path)", result: &result)
        }
        for path in expected.expectedAppPaths {
            check(archive.entry(at: path)?.kind == .app && archive.entry(at: path)?.isFolder == true,
                  "Missing listed app bundle \(path)", result: &result)
        }
        for (path, size) in expected.expectedPresentationFiles {
            check(archive.presentationFiles[path] == size, "Presentation metadata missing/wrong size: \(path)", result: &result)
        }
        let storePath = expected.expectedRoot.isEmpty ? ".DS_Store" : expected.expectedRoot + "/.DS_Store"
        if expected.expectedStoreSize == nil {
            check(archive.presentationFiles[storePath] == nil, "Unexpected root .DS_Store", result: &result)
        } else {
            check(archive.presentationFiles[storePath] == expected.expectedStoreSize,
                  "Root .DS_Store was confused with another file or alternate stream", result: &result)
        }
        check(!archive.presentationFiles.keys.contains { $0.contains(".DS_Store:") },
              "Alternate stream leaked into presentation metadata", result: &result)

        let source = try #require(archive.source)
        // Exact paths, sizes and SHA-256 come from direct 7-Zip reference reads in the wrapper.
        // These trips exercise extraction and metadata without extracting a whole app bundle.
        var wanted: [String: Int64] = [:]
        for file in expected.referenceFiles {
            guard file.size >= 0, file.size <= 24 << 20 else { throw CorpusError.invalidReference(file.path) }
            wanted[file.path] = max(file.size, 1)
        }
        if !wanted.isEmpty {
            let read = try await ArchiveFileReader.read(wanted, from: archive, source: source, password: nil)
            for file in expected.referenceFiles {
                guard let data = read[file.path] else {
                    result.failures.append("Bounded XPC extraction did not return \(file.path)")
                    continue
                }
                check(Int64(data.count) == file.size, "Extracted size differs: \(file.path)", result: &result)
                check(Self.sha256(data) == file.sha256, "Extracted SHA-256 differs: \(file.path)", result: &result)
                result.verifiedReferencePaths.append(file.path)
                if file.path.hasSuffix("/Contents/Info.plist") {
                    check((try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any],
                          "App Info.plist could not be decoded: \(file.path)", result: &result)
                }
            }
        }

        let icons = await ArchivedAppIcon.load(expected.expectedAppPaths, in: archive, password: nil)
        result.decodedIconPaths = icons.keys.sorted()
        for path in expected.expectedIconApps {
            check(icons[path] != nil, "Declared app icon did not decode: \(path)", result: &result)
        }
        for (app, wanted) in expected.expectedIconPaths ?? [:] {
            let plist = try await ArchiveFileReader.read([ArchivedAppIcon.plistPath(app: app): 1 << 20],
                                                        from: archive, source: source, password: nil)
            check(ArchivedAppIcon.iconFile(app: app, plist: plist[ArchivedAppIcon.plistPath(app: app)], in: archive) == wanted,
                  "Declared icon selection differs for \(app)", result: &result)
        }
        let canvas = await InstallerCanvasLoader.load(archive, password: nil)
        result.canvasLoaded = canvas != nil
        if let wanted = expected.expectedCanvas {
            check((canvas != nil) == wanted, "Canvas presence: expected \(wanted)", result: &result)
        } else {
            result.unverified.append("Canvas presence has no independent layout expectation")
        }
        if let canvas {
            result.backgroundLoaded = canvas.background != nil
            result.backgroundSize = canvas.backgroundSize.map { [$0.width, $0.height] }
            result.iconSize = canvas.layout.iconSize
            result.textSize = canvas.layout.textSize
            result.windowSize = canvas.layout.windowSize.map { [$0.width, $0.height] }
            result.positions = canvas.layout.positions.mapValues { [$0.x, $0.y] }
            result.canvasIconPaths = canvas.icons.keys.sorted()
            switch canvas.layout.background {
            case .plain: result.backgroundKind = "plain"
            case .color: result.backgroundKind = "color"
            case .picture(let paths): result.backgroundKind = "picture"; result.backgroundCandidates = paths
            }
            if let wanted = expected.expectedBackground {
                check((canvas.background != nil) == wanted, "Background decode presence differs", result: &result)
            }
            if let wanted = expected.expectedBackgroundSize {
                check(result.backgroundSize == wanted, "Background point size differs: expected \(wanted), got \(String(describing: result.backgroundSize))", result: &result)
            }
            if let wanted = expected.expectedIconSize {
                check(canvas.layout.iconSize == wanted, "Authored icon size differs", result: &result)
            }
            if let wanted = expected.expectedTextSize {
                check(canvas.layout.textSize == wanted, "Authored text size differs", result: &result)
            }
            if let wanted = expected.expectedBackgroundKind {
                check(result.backgroundKind == wanted, "Authored background kind differs", result: &result)
            }
            if let wanted = expected.expectedWindowSize {
                check(result.windowSize == wanted, "Authored content window size differs", result: &result)
            }
            if let wanted = expected.expectedBackgroundPath {
                let candidates = result.backgroundCandidates.compactMap { InstallerLayout.archivePath($0, volumeRoot: expected.expectedRoot) }
                check(candidates.contains(wanted), "Background alias did not resolve to reference path \(wanted)", result: &result)
            }
            for (name, point) in expected.expectedPositions ?? [:] {
                check(result.positions[name] == point, "Authored position differs for \(name)", result: &result)
            }
            for path in expected.expectedIconApps {
                check(canvas.icons[path] != nil, "Canvas lost the declared app icon: \(path)", result: &result)
            }
        }
        if expected.expectedCanvas == true && expected.expectedBackground == nil {
            result.unverified.append("Background presence/geometry has no independent expectation")
        }
        if ProcessInfo.processInfo.environment["STOW_DMG_CORPUS_PAYLOADS"] == "1" {
            try await inspectPayload(archive, expected: expected, result: &result)
        }
        if expected.expectedAppPaths.count > expected.expectedIconApps.count {
            result.unverified.append("Some app icon formats have no independent decode expectation")
        }
    }

    /// Exercise the complete engine → pipe → app staging path without publishing or launching
    /// a vendor payload. The same staging and signature checks precede an ordinary installation.
    private func inspectPayload(_ archive: Archive, expected: ImageExpectation, result: inout ImageResult) async throws {
        let selection = archive.children(of: archive.volumeRoot).filter { !$0.isHelper }
        guard !selection.isEmpty else { throw CorpusError.invalidReference("No payload entries") }
        let destination = try TemporaryFolder()
        defer { destination.cleanUp() }
        let staged = try await Extraction.stage(archive, selection: selection, near: destination.url, onProgress: { _ in })
        defer { staged.discard() }
        result.payloadExtracted = true
        check(staged.report.removedItems.isEmpty, "Payload items removed: \(staged.report.removedItems)", result: &result)
        check(staged.report.removedLinks.isEmpty, "Payload links removed: \(staged.report.removedLinks)", result: &result)
        for entry in selection {
            let url = staged.url(for: entry)
            check(Extraction.exists(url), "Missing extracted payload \(entry.path)", result: &result)
            if entry.kind == .app {
                let facts = await Self.signatureFacts(for: url)
                result.payloadSignatures[entry.path] = String(describing: facts.validity)
                if let baseline = expected.expectedSignatureValidity?[entry.path] {
                    check(String(describing: facts.validity) == baseline,
                          "Signature differs from independently verified source for \(entry.path)", result: &result)
                    if facts.validity != .valid {
                        result.unverified.append("Source bundle also has \(baseline): \(entry.path); extraction preserves that status")
                    }
                    continue
                }
                switch facts.validity {
                case .valid: break
                case .unsigned: result.unverified.append("Unsigned vendor bundle: \(entry.path)")
                case .invalid(let status): result.failures.append("Extracted app signature invalid (\(status)): \(entry.path)")
                }
            }
        }
    }

    @concurrent
    private static func signatureFacts(for url: URL) async -> CodeSignature.Facts {
        CodeSignature.facts(for: url)
    }

    private func check(_ condition: Bool, _ message: String, result: inout ImageResult) {
        if !condition { result.failures.append(message) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func report(_ results: [ImageResult], manifest: Manifest) -> String {
        let failures = results.reduce(0) { $0 + $1.failures.count }
        var text = "# Real DMG corpus results\n\n\(results.count)/\(manifest.images.count) images completed; \(failures) failed checks.\n\n"
        text += "| Image | Result | Entries | Canvas | Background | Icons | Seconds |\n| --- | --- | ---: | --- | --- | ---: | ---: |\n"
        for result in results {
            text += "| \(result.filename.replacingOccurrences(of: "|", with: "\\|")) | \(result.failures.isEmpty ? "PASS" : "FAIL") | \(result.listedEntries) | \(result.canvasLoaded) | \(result.backgroundLoaded) | \(result.decodedIconPaths.count) | \(String(format: "%.2f", result.durationSeconds)) |\n"
        }
        text += "\nVerified actual ArchiveEngine XPC listing, Archive model roots/apps/presentation metadata, InstallerCanvasLoader, declared app icons, and bounded reference-file extraction with byte hashes.\n\n"
        text += "Full payload extraction and strict nested signature checks are recorded per image when --payloads is enabled. Not verified: launching or installing third-party payloads; Finder installation; UI visual/motion acceptance; actual VoiceOver use. Layout/background assertions are limited to independent expectations supplied in the manifest. No writes to /Applications.\n"
        for result in results where !result.failures.isEmpty || !result.unverified.isEmpty {
            text += "\n## \(result.filename)\n\n"
            for failure in result.failures { text += "- FAIL: \(failure)\n" }
            for limitation in result.unverified { text += "- Unverified: \(limitation)\n" }
        }
        return text
    }

    private nonisolated struct Manifest: Decodable, Sendable {
        let schemaVersion: Int
        let stageDirectory: String
        let reportDirectory: String
        let images: [ImageExpectation]
    }

    private nonisolated struct ImageExpectation: Decodable, Sendable {
        let id: String
        let filename: String
        let stagedPath: String
        let expectedRoot: String
        let expectedAppPaths: [String]
        let expectedInstallablePath: String?
        let expectedDropTargets: [String: String]
        let expectedPresentationFiles: [String: Int64]
        let expectedStoreSize: Int64?
        let referenceFiles: [ReferenceFile]
        let expectedIconApps: [String]
        let expectedIconPaths: [String: String]?
        let expectedSignatureValidity: [String: String]?
        let expectedCanvas: Bool?
        let expectedBackground: Bool?
        let expectedBackgroundSize: [Double]?
        let expectedIconSize: Double?
        let expectedTextSize: Double?
        let expectedBackgroundKind: String?
        let expectedWindowSize: [Double]?
        let expectedPositions: [String: [Double]]?
        let expectedBackgroundPath: String?
    }

    private nonisolated struct ReferenceFile: Decodable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    private nonisolated struct ImageResult: Encodable, Sendable {
        let id: String
        let filename: String
        var durationSeconds = 0.0
        var listedEntries = 0
        var payloadExtracted = false
        var payloadSignatures: [String: String] = [:]
        var volumeRoot = ""
        var visibleRootNames: [String] = []
        var presentationFiles: [String: Int64] = [:]
        var dropTargetPaths: [String] = []
        var dropTargets: [String: String] = [:]
        var installablePath: String?
        var checkup: [String] = []
        var verifiedReferencePaths: [String] = []
        var decodedIconPaths: [String] = []
        var canvasLoaded = false
        var backgroundLoaded = false
        var backgroundSize: [Double]?
        var backgroundKind: String?
        var backgroundCandidates: [String] = []
        var iconSize: Double?
        var textSize: Double?
        var windowSize: [Double]?
        var positions: [String: [Double]] = [:]
        var canvasIconPaths: [String] = []
        var failures: [String] = []
        var unverified: [String] = []
    }

    private nonisolated enum CorpusError: Error {
        case invalidStagedPath(String)
        case invalidReference(String)
    }
}
#endif
