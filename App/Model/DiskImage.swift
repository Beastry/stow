import Foundation

/// Disk images are browsed through the engine, read-only and without mounting: 7-Zip reads HFS+,
/// APFS and ISO 9660 straight from the file, so nothing is attached, nothing needs detaching, and a
/// busy or already-mounted image opens just the same.
///
/// What a developer adds to lay out the Finder window — background art, a volume icon, the
/// "drag here" shortcut to Applications — isn't content. It's hidden, left out when extracting, and
/// the shortcuts become install targets.
nonisolated enum DiskImageLayout {
    /// Top-level names on a volume that are layout or file-system bookkeeping.
    static let extraNames: Set<String> = [
        ".background", ".VolumeIcon.icns", ".DS_Store", ".fseventsd", ".Trashes", ".Spotlight-V100",
        ".HFS+ Private Directory Data\r", ".HFS+ Private Directory Data", "[HFS+ Private Data]", ".journal", ".journal_info_block",
        ".TemporaryItems", ".DocumentRevisions-V100", ".apdisk", ".com.apple.timemachine.donotpresent",
        ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
    ]

    /// What the author put on the volume to dress its window, as opposed to file-system bookkeeping
    /// (`.fseventsd`, `.Trashes`, HFS+ private data…), which stays out of sight.
    static let authoredNames: Set<String> = [".background", ".VolumeIcon.icns", ".DS_Store"]
    /// Finder installers also use the localized Applications name in the image itself.
    static let applicationsNames: Set<String> = ["Applications", "应用程序"]

    /// Some image builders place the picture beside `.DS_Store`, rather than in a folder.
    /// Match their exact basename, not every hidden picture or arbitrary `.background.*` data.
    static func isBackgroundPicture(_ name: String) -> Bool {
        guard name.hasPrefix(".background.") else { return false }
        return ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "avif"]
            .contains(String(name.dropFirst(".background.".count)).lowercased())
    }

    /// A shortcut on the volume, like "Applications → /Applications": the developer's "drag here".
    struct DropTarget: Hashable, Sendable {
        /// The link's path in the browser.
        let path: String
        /// Absolute folder it points at.
        let folder: String

        var name: String { (path as NSString).lastPathComponent }
        var url: URL { URL(filePath: folder, directoryHint: .isDirectory) }
    }

    struct Layout: Equatable, Sendable {
        var volumeRoot = ""
        /// Contained paths of hidden top-level items (drop-target links included).
        var extras: [String] = []
        var dropTargets: [DropTarget] = []

        /// The author's window dressing — the background folder, the volume icon, the window's
        /// store and the "drag here" shortcuts — is listed, dimmed like a Mac's helper items, so
        /// everything in the image can be seen, as ArcZip lists it. It still isn't content: Extract
        /// All leaves it out and the installer window doesn't place it.
        func isAuthoredExtra(_ path: String) -> Bool {
            if dropTargets.contains(where: { $0.path == path }) { return true }
            let prefix = volumeRoot.isEmpty ? "" : volumeRoot + "/"
            guard path.hasPrefix(prefix) else { return false }
            let first = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
            return DiskImageLayout.authoredNames.contains(first) || DiskImageLayout.isBackgroundPicture(first)
        }

        func hides(_ path: String) -> Bool {
            extras.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        /// The volume's `.DS_Store`, or a file at most one folder deep in its hidden layout items
        /// (`.background/bg.png`): what the author's window is drawn from.
        func isPresentationFile(_ path: String) -> Bool {
            let prefix = volumeRoot.isEmpty ? "" : volumeRoot + "/"
            guard path.hasPrefix(prefix) else { return false }
            let relative = path.dropFirst(prefix.count)
            if relative == ".DS_Store" { return true }
            guard let first = relative.split(separator: "/").first, first.hasPrefix("."),
                  relative.split(separator: "/").count <= 2 else { return false }
            return hides(path)
        }
    }

    /// `entries` with contained paths. HFS+ images list everything under the volume's name;
    /// APFS and ISO images list the volume's contents at the top.
    static func layout(of entries: [(path: String, isFolder: Bool, isSymlink: Bool, linkTarget: String?)],
                       aliasDropTargets: [DropTarget] = []) -> Layout {
        var layout = Layout()
        let firsts = Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
        if firsts.count == 1, let only = firsts.first, isVolumeFolder(only, in: entries) {
            layout.volumeRoot = only
        }
        let prefix = layout.volumeRoot.isEmpty ? "" : layout.volumeRoot + "/"
        var extras = Set<String>()
        for entry in entries where entry.path.hasPrefix(prefix) {
            let relative = String(entry.path.dropFirst(prefix.count))
            guard let top = relative.split(separator: "/").first.map(String.init) else { continue }
            // Listings needn't hold an entry for each folder: `.background/bg.png` alone hides `.background`.
            if extraNames.contains(top) || (top == relative && !entry.isFolder && isBackgroundPicture(top)) {
                extras.insert(prefix + top)
            } else if top == relative, entry.isSymlink, let folder = dropFolder(name: relative, target: entry.linkTarget) {
                extras.insert(entry.path)
                layout.dropTargets.append(DropTarget(path: entry.path, folder: folder))
            } else if top == relative, !entry.isFolder, !entry.isSymlink,
                      let target = aliasDropTargets.first(where: { $0.path == entry.path }),
                      isSafeDropFolder(target.folder) {
                extras.insert(entry.path)
                layout.dropTargets.append(target)
            }
        }
        layout.extras = extras.sorted()
        return layout
    }

    /// Folders that are a single thing to install or open, even where the system doesn't register
    /// the type as a package.
    private static let packageExtensions: Set<String> = ["app", "pkg", "mpkg", "rtfd", "bundle"]

    /// HFS+ lists everything under the volume's name, and volume names are often versions
    /// ("PikPak-v2.7.1.2480"), so a dot doesn't make the sole top-level folder a file. A real
    /// package there (`Tool.app`, `Setup.pkg`, `Notes.rtfd`) is content, not the volume, and an
    /// explicit file or link at the top is never a volume.
    private static func isVolumeFolder(_ name: String,
                                       in entries: [(path: String, isFolder: Bool, isSymlink: Bool, linkTarget: String?)]) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !name.isEmpty, !ArchiveEntry.isPackageName(name), !packageExtensions.contains(ext),
              entries.contains(where: { $0.path.hasPrefix(name + "/") }) else { return false }
        return entries.allSatisfy { $0.path != name || ($0.isFolder && !$0.isSymlink) }
    }

    /// APFS listings carry the link target; HFS+ ones don't, so a link named "Applications" is
    /// taken at its word.
    private static func dropFolder(name: String, target: String?) -> String? {
        if let target, target.hasPrefix("/") { return target }
        if (target ?? "").isEmpty, applicationsNames.contains(name) { return "/Applications" }
        return nil
    }

    /// Cached bookmark paths are descriptive metadata, never resolved on this Mac.
    static func isSafeDropFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4_096 && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}
