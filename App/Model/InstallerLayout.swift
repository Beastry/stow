import CoreGraphics
import DSStore
import Foundation

/// The window a disk image's author laid out for Finder (#344): the volume's `.DS_Store` gives the
/// background, icon size and where each item sits. Read from bytes taken out of the archive; it
/// never resolves anything against this Mac's file system or mounts the image.
///
/// Every value is checked: a store from the internet may claim anything. What doesn't hold up is
/// dropped, and with nothing usable left there is no layout and the volume browses as usual.
nonisolated struct InstallerLayout: Equatable, Sendable {
    enum Background: Equatable, Sendable {
        /// Finder's plain window.
        case plain
        case color(red: Double, green: Double, blue: Double)
        /// A picture inside the volume: where it may be, relative to the volume's top
        /// ("/.background/bg.png"), most likely first.
        case picture(volumePaths: [String])
    }

    var background: Background = .plain
    /// The window's content size in points, when the store says.
    var windowSize: CGSize?
    var iconSize: CGFloat = 64
    var textSize: CGFloat = 12
    /// Icon centres in the window's coordinates (points, origin at the top left), by item name.
    var positions: [String: CGPoint] = [:]

    /// Bigger stores are not a window's layout.
    static let maxStoreBytes = 4 << 20
    static let maxPositions = 2_000
    /// Icon centres beyond this are not on any window anyone could open.
    static let coordinateRange: ClosedRange<Int> = -512...16_384
    /// Finder's title bar, which the stored window bounds include.
    static let titleBarHeight: CGFloat = 28

    /// Nil when the bytes aren't a store, or it says nothing about icon positions or a picture.
    static func read(_ data: Data) -> InstallerLayout? {
        guard data.count <= maxStoreBytes, let store = try? DSStore.read(from: data) else { return nil }
        var layout = InstallerLayout()

        let settings = store.iconViewSettings()
        let legacy = legacySettings(in: store)
        if let size = settings?.iconSize ?? legacy.iconSize, (16...512).contains(size) { layout.iconSize = CGFloat(size) }
        if let size = settings?.textSize ?? legacy.textSize, (9...20).contains(size) { layout.textSize = CGFloat(size) }
        switch store.background() ?? legacy.background {
        case .color(let red, let green, let blue)?:
            let channels = [red, green, blue].map { min(max($0.isFinite ? $0 : 1, 0), 1) }
            layout.background = .color(red: channels[0], green: channels[1], blue: channels[2])
        case .picture(let alias)?:
            let paths = CarbonAlias.volumePaths(in: alias)
            if !paths.isEmpty { layout.background = .picture(volumePaths: paths) }
        default: break
        }

        if let frame = store.windowSettings()?.windowBoundsValue {
            layout.windowSize = validWindow(width: frame.width, height: frame.height - titleBarHeight)
        } else if let bounds = store.windowBounds() {
            layout.windowSize = validWindow(width: Double(bounds.width), height: Double(bounds.height) - titleBarHeight)
        }

        for record in store.records where record.type == .iconLocation {
            guard layout.positions.count < maxPositions,
                  isItemName(record.filename),
                  let position = record.iconPosition,
                  coordinateRange.contains(position.x), coordinateRange.contains(position.y) else { continue }
            layout.positions[record.filename] = CGPoint(x: position.x, y: position.y)
        }

        if layout.positions.isEmpty, case .plain = layout.background { return nil }
        return layout
    }

    /// Older Finder/dmgcanvas windows (including ArcZip) keep the same information in separate
    /// records instead of `icvp`. Read only directory records and let modern settings win.
    private static func legacySettings(in store: DSStore) -> (iconSize: Int?, textSize: Int?, background: DSStore.BackgroundType?) {
        func record(_ code: String) -> DSStore.Value? {
            store.records.first { $0.filename == "." && $0.type.fourCC.stringValue == code }?.value
        }
        var iconSize: Int?
        if case .data(let data)? = record("icvo"), data.count >= 6, data.prefix(4) == Data("icv4".utf8) {
            iconSize = Int(data[4]) << 8 | Int(data[5])
        }
        let textSize: Int?
        if case .uint16(let size)? = record("icvt") { textSize = Int(size) } else { textSize = nil }
        var background: DSStore.BackgroundType?
        if case .data(let data)? = record("BKGD"), data.count >= 12 {
            switch String(data: data.prefix(4), encoding: .ascii) {
            case "DefB": background = .default
            case "ClrB":
                let channels = [4, 6, 8].map { Double(Int(data[$0]) << 8 | Int(data[$0 + 1])) / 65_535 }
                background = .color(red: channels[0], green: channels[1], blue: channels[2])
            case "PctB":
                let length = data[4..<8].reduce(0) { ($0 << 8) | Int($1) }
                if case .data(let alias)? = record("pict"), length > 0, length <= alias.count {
                    background = .picture(aliasData: Data(alias.prefix(length)))
                }
            default: break
            }
        }
        return (iconSize, textSize, background)
    }

    /// The canvas: the window, grown to hold every placed icon and its name.
    func canvasSize(background: CGSize?, placed names: some Sequence<String>) -> CGSize {
        var size = background ?? windowSize ?? .zero
        for name in names {
            guard let center = positions[name] else { continue }
            size.width = max(size.width, center.x + iconSize / 2 + 8)
            size.height = max(size.height, center.y + iconSize / 2 + labelHeight + 8)
        }
        return CGSize(width: max(size.width, iconSize * 2), height: max(size.height, iconSize * 2))
    }

    /// Room under an icon for a two-line name.
    var labelHeight: CGFloat { (textSize * 1.3).rounded(.up) * 2 + 6 }

    private static func validWindow(width: Double, height: Double) -> CGSize? {
        guard width.isFinite, height.isFinite, (120...8_192).contains(width), (80...8_192).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// One item directly in the folder: not the folder itself, not a path.
    private static func isItemName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 1_024
    }

    /// The archive path a volume path names: inside the volume, or nil.
    static func archivePath(_ volumePath: String, volumeRoot: String) -> String? {
        let parts = volumePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 8, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let joined = parts.joined(separator: "/")
        return volumeRoot.isEmpty ? joined : volumeRoot + "/" + joined
    }
}

/// Just enough of a Carbon Alias record to learn which file in the volume a background picture is.
/// Finder stores the picture as an alias; the parts that matter here are the volume-relative POSIX
/// path (tag 18) or, in older records, the parent folder's name (tag 0) with the file's name.
/// Volume names, mount points and file IDs are deliberately ignored: they describe the author's Mac.
nonisolated enum CarbonAlias {
    /// Where the alias's file may be, relative to the volume's top, most likely first. Empty when
    /// the record isn't one this reads.
    static func volumePaths(in data: Data) -> [String] {
        let bytes = [UInt8](data.prefix(4_096))
        guard bytes.count >= 10 else { return [] }
        let version = Int(bytes[6]) << 8 | Int(bytes[7])
        let start: Int
        var fileName: String?
        switch version {
        case 2:
            // Version 2: a 150-byte fixed part, the file's name a Pascal string at 50.
            guard bytes.count >= 150 else { return [] }
            let length = min(Int(bytes[50]), 63)
            fileName = String(bytes: bytes[51..<(51 + length)], encoding: .macOSRoman)
            start = 150
        case 3:
            start = 58
        default:
            return []
        }

        var parent: String?
        var unicodeName: String?
        var offset = start
        while offset + 4 <= bytes.count {
            let tag = Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard tag != -1, offset + length <= bytes.count else { break }
            let value = Array(bytes[offset..<(offset + length)])
            switch tag {
            case 18:
                if let path = String(bytes: value, encoding: .utf8), path.hasPrefix("/") { return [path] }
            case 0:
                parent = String(bytes: value, encoding: .macOSRoman)
            case 14:
                // A UTF-16 character count, then big-endian UTF-16.
                if value.count >= 2 {
                    let count = Int(value[0]) << 8 | Int(value[1])
                    if value.count >= 2 + count * 2 {
                        unicodeName = String(bytes: value[2..<(2 + count * 2)], encoding: .utf16BigEndian)
                    }
                }
            default: break
            }
            offset += length + (length & 1)
        }
        guard let name = unicodeName ?? fileName, !name.isEmpty, !name.contains("/") else { return [] }
        // The parent of a file at the volume's top is the volume itself, so try both.
        if let parent, !parent.isEmpty, !parent.contains("/") { return ["/\(parent)/\(name)", "/\(name)"] }
        return ["/\(name)"]
    }
}
