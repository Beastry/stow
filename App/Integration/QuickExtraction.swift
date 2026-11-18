import Foundation

/// Settings › Extraction › Double-click extracts (#328): an archive opened from Finder is extracted
/// next to itself, as Finder's Extract Here does, instead of opening a window. Off by default.
///
/// What macOS hands Stow for a document open is the same `odoc` Apple Event (the files, plus a
/// Launch Services parameter) whether Finder opened the file by double-click, Open With or a drop
/// on the app; nothing in it says which. What differs is the process that asked: the event's
/// sender. So the rule is about where the open came from, not how:
/// - Finder: extracts. The folder the archive sits in is the one the person is looking at.
/// - Anything else (Quick Look's Open in Stow, the Dock, Mail, WeChat, `open`): opens as usual.
///   Those files often sit in another app's container, where a result next to them would be lost.
/// - Shift held as the open arrives, Finder's own Open in Stow (a `stow://` hand-off), File ›
///   Open and Open Recent: open as usual.
/// - Disk images and installer packages always open, as do files Stow doesn't list as archives
///   (an .exe tried with Open With) and archives already open in a window (it comes forward).
nonisolated enum QuickExtraction {
    static let finder = "com.apple.finder"

    /// How a document open reached Stow.
    struct Origin: Equatable, Sendable {
        /// The sender's bundle identifier, when macOS says.
        var sender: String?
        /// Shift was held: browse this time.
        var browseHeld = false

        var isFinder: Bool { sender == QuickExtraction.finder && !browseHeld }
    }

    /// Which archives to extract right away, and which to open as before, in the order given.
    static func route(_ urls: [URL], enabled: Bool, origin: Origin?,
                      isOpen: (URL) -> Bool) -> (extract: [URL], open: [URL]) {
        guard enabled, origin?.isFinder == true else { return ([], urls) }
        var extract: [URL] = [], open: [URL] = []
        for url in urls {
            if extracts(url), !isOpen(url) { extract.append(url) } else { open.append(url) }
        }
        return (extract, open)
    }

    /// Archives only; never disk images or installer packages, which have better homes.
    static func extracts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = ArchiveTypes.type(forFileName: url.lastPathComponent) else { return false }
        return type.group != .diskImages && type.id != "com.apple.installer-package-archive"
    }

    /// A double-click never stops to ask: only an explicit Moves to the Trash removes the original.
    static func afterwards(_ setting: Preferences.AfterwardsArchive) -> Preferences.AfterwardsArchive {
        setting == .trash ? .trash : .keep
    }
}
