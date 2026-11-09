import AppKit
import ImageIO
import SwiftUI

/// An app inside an archive shows its own icon, as Finder and ArcZip do, not the system's generic
/// app icon (#344). The icon is the file its `Info.plist` names (`CFBundleIconFile`), or the
/// `AppIcon.icns` Xcode writes beside an asset catalog, read straight out of the archive: two small
/// extractions, never the whole app. Nothing is launched, registered or mounted, and every size is
/// capped before anything is decoded.
enum ArchivedAppIcon {
    static let maxPlistBytes: Int64 = 1 << 20
    static let maxIconBytes: Int64 = 24 << 20
    /// The largest icon representation decoded; macOS icons top out at 1024 px.
    nonisolated static let maxIconPixels = 1_024
    /// Apps read together in one request.
    static let maxApps = 32

    /// An app bundle whose files the listing has: the only kind with an icon to read.
    static func applies(to entry: ArchiveEntry) -> Bool {
        entry.kind == .app && entry.isFolder
    }

    static func plistPath(app: String) -> String { app + "/Contents/Info.plist" }

    /// The icon an app's Info.plist names, inside that app's Resources.
    static func iconPath(app: String, plist data: Data) -> String? {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var name = info["CFBundleIconFile"] as? String, !name.isEmpty,
              !name.contains("/"), name != ".", name != ".." else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".icns" }
        return app + "/Contents/Resources/" + name
    }

    /// The listed icon file to read for an app: the declared one, else Xcode's `AppIcon.icns`.
    static func iconFile(app: String, plist: Data?, in archive: Archive) -> String? {
        let declared = plist.flatMap { iconPath(app: app, plist: $0) }
        for path in [declared, app + "/Contents/Resources/AppIcon.icns"].compactMap(\.self) {
            if let entry = archive.entry(at: path), !entry.isFolder, entry.size <= maxIconBytes { return path }
        }
        return nil
    }

    /// Reads the icons of these apps (paths in `archive`) in two engine trips: their Info.plists,
    /// then the icon files they name. Apps without a readable icon are left out.
    static func load(_ apps: [String], in archive: Archive, password: String?) async -> [String: NSImage] {
        guard let source = archive.source else { return [:] }
        let apps = Array(apps.prefix(maxApps))
        var plists: [String: Int64] = [:]
        for app in apps {
            let path = plistPath(app: app)
            if let entry = archive.entry(at: path), !entry.isFolder, entry.size <= maxPlistBytes {
                plists[path] = maxPlistBytes
            }
        }
        let plistData = plists.isEmpty ? [:] : ((try? await ArchiveFileReader.read(plists, from: archive, source: source, password: password)) ?? [:])
        guard !Task.isCancelled else { return [:] }

        var iconPaths: [String: String] = [:]
        for app in apps {
            if let path = iconFile(app: app, plist: plistData[plistPath(app: app)], in: archive) { iconPaths[app] = path }
        }
        guard !iconPaths.isEmpty else { return [:] }
        let wanted = Dictionary(iconPaths.values.map { ($0, maxIconBytes) }, uniquingKeysWith: { first, _ in first })
        guard let files = try? await ArchiveFileReader.read(wanted, from: archive, source: source, password: password),
              !Task.isCancelled else { return [:] }
        var icons: [String: NSImage] = [:]
        for (app, path) in iconPaths {
            if let data = files[path], let image = await decode(data) { icons[app] = image }
        }
        return icons
    }

    /// Decodes an icon file off the main thread: every representation up to 1024 px, so small
    /// rows get the artist's small drawing and Details the large one. Anything larger is refused.
    @concurrent
    nonisolated static func decode(_ data: Data) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 16)
        var reps: [NSBitmapImageRep] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...maxIconPixels).contains(width), (1...maxIconPixels).contains(height),
                  let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            reps.append(NSBitmapImageRep(cgImage: image))
        }
        guard !reps.isEmpty else { return nil }
        // All representations share one size in points; drawing picks the closest in pixels.
        let size = CGSize(width: 32, height: 32)
        let image = NSImage(size: size)
        for rep in reps {
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }
}

/// Extracts exactly the listed files asked for into a private folder, reads them and removes the
/// folder. Each path maps to the largest size accepted; links, folders and anything larger are
/// skipped. The app-icon and disk-image-window readers share it.
enum ArchiveFileReader {
    static func read(_ wanted: [String: Int64], from archive: Archive, source: ArchiveSource,
                     password: String?) async throws(EngineError) -> [String: Data] {
        var stored: [String] = []
        var helpers: [String] = []
        for path in wanted.keys {
            guard let name = source.storedPaths[path]?.first else { continue }
            stored.append(name)
            if MacHelperFiles.matches(name) { helpers.append(name) }
        }
        guard !stored.isEmpty else { return [:] }
        let engine = ArchiveEngine.shared
        let output = try await engine.extract(source.url, paths: stored, password: password,
                                              preservedHelperPaths: helpers) { _ in }
        defer { engine.discard(output) }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ArchiveFileReader-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw EngineError(.failed, error.localizedDescription)
        }
        try await engine.receive(output, into: folder)
        LegacyNames.repair(source.renamed, in: folder)

        var found: [String: Data] = [:]
        for (path, limit) in wanted {
            let url = folder.appending(path: path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? .max) <= limit,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            found[path] = Data(data)
        }
        return found
    }
}

/// An app's own icon wherever an entry's picture goes: the generic app icon until it's read, or
/// for good when the app names none Stow can read.
struct ArchivedAppIconView: View {
    let entry: ArchiveEntry
    let model: BrowserModel

    @State private var loaded: (id: String, image: NSImage)?

    var body: some View {
        let archive = model.archive
        let id = "\(archive.id)\(entry.id)\(model.previewRevision)"
        Group {
            if let image = loaded?.id == id ? loaded?.image : model.previews.cachedAppIcon(for: entry, in: archive) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity.animation(Motion.current(Motion.preview)))
            } else {
                NativeIcon(type: entry.contentType)
            }
        }
        .task(id: id) {
            guard archive.source != nil, model.previews.cachedAppIcon(for: entry, in: archive) == nil,
                  let image = await model.previews.appIcon(for: entry, in: archive), !Task.isCancelled else { return }
            loaded = (id, image)
        }
    }
}
