// Writes the authored-window assets for Tests/Fixtures/Fixture-Layout.dmg (#344): a `.DS_Store`
// with icon positions, icon/text sizes and a picture background whose Carbon Alias points at
// `/.background/bg@2x.png`, the 2x artwork itself, and a 512 px app icon picture.
//
// scripts/make-fixtures.sh compiles this with ThirdParty/DSStore's sources and runs it into a work folder.
// --compatibility emits an 8 KiB-leaf store, a root multi-resolution TIFF, and a regular Finder
// bookmark to /Applications. All pictures and metadata are generated here, with no vendor bytes.
// Usage: make-layout <output folder> [--compatibility]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
let compatibility = CommandLine.arguments.dropFirst(2).contains("--compatibility")

/// A version 2 alias record: the fixed 150-byte part, then tagged extras (parent name, Unicode
/// file name, volume-relative POSIX path), ending with tag -1.
func alias(volume: String, parent: String, file: String) -> Data {
    var data = Data(count: 150)
    func pascal(_ text: String, at offset: Int, max: Int) {
        let bytes = Array(text.data(using: .macOSRoman, allowLossyConversion: true)!.prefix(max))
        data[offset] = UInt8(bytes.count)
        data.replaceSubrange((offset + 1)..<(offset + 1 + bytes.count), with: bytes)
    }
    data[7] = 2 // version
    pascal(volume, at: 10, max: 27)
    data.replaceSubrange(42..<44, with: Array("H+".utf8))
    pascal(file, at: 50, max: 63)
    func tag(_ tag: Int16, _ value: [UInt8]) {
        data.append(contentsOf: [UInt8(UInt16(bitPattern: tag) >> 8), UInt8(UInt16(bitPattern: tag) & 0xFF),
                                 UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
        data.append(contentsOf: value)
        if value.count % 2 == 1 { data.append(0) }
    }
    tag(0, Array(parent.utf8))
    let units = Array(file.utf16)
    tag(14, [UInt8(units.count >> 8), UInt8(units.count & 0xFF)] + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    tag(18, Array(("/" + [parent, file].filter { !$0.isEmpty }.joined(separator: "/")).utf8))
    tag(-1, [])
    data[4] = UInt8(data.count >> 8)
    data[5] = UInt8(data.count & 0xFF)
    return data
}

func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return context.makeImage()!
}

func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image(width: width, height: height, draw: draw), nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// 800 × 500 pixels, drawn at 400 × 250 points: dark art with light name plates under both icons.
try png(width: 800, height: 500, to: out.appending(path: "bg@2x.png")) { context in
    context.setFillColor(CGColor(srgbRed: 0.10, green: 0.14, blue: 0.26, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
    context.setFillColor(CGColor(srgbRed: 0.75, green: 0.80, blue: 0.90, alpha: 1))
    // Plates under the names: centred on x 100 and 300 points, 174–196 points from the top (the
    // icons' centres are at 120 and they are 96 points tall). The context draws bottom up.
    for x in [100.0, 300.0] {
        context.fill(CGRect(x: (x - 45) * 2, y: (250 - 196) * 2, width: 180, height: 44))
    }
}
try png(width: 512, height: 512, to: out.appending(path: "icon.png")) { context in
    context.setFillColor(CGColor(srgbRed: 0.95, green: 0.45, blue: 0.15, alpha: 1))
    context.fillEllipse(in: CGRect(x: 32, y: 32, width: 448, height: 448))
}

/// Independently pack a single 8 KiB leaf with the logical page size still 4 KiB, as Finder does.
/// A harmless extra icvp property makes the actual settings record cross the first page. The
/// package writer deliberately uses smaller pages, so it cannot author this regression case.
func largeLeafStore(_ store: DSStore) throws -> Data {
    func word(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    let records = store.records.sorted {
        let order = $0.filename.compare($1.filename, options: [.caseInsensitive, .literal], locale: Locale(identifier: "en_US_POSIX"))
        return order == .orderedSame ? $0.type.fourCC.rawValue < $1.type.fourCC.rawValue : order == .orderedAscending
    }
    var payload = Data()
    for record in records {
        payload.append(word(UInt32(record.filename.utf16.count)))
        payload.append(record.filename.data(using: .utf16BigEndian)!)
        payload.append(word(record.type.fourCC.rawValue))
        switch record.value {
        case .data(let bytes):
            payload.append(Data("blob".utf8)); payload.append(word(UInt32(bytes.count))); payload.append(bytes)
        case .propertyList(let value):
            let bytes = try value.serialized()
            payload.append(Data("blob".utf8)); payload.append(word(UInt32(bytes.count))); payload.append(bytes)
        case .fourCC(let code):
            payload.append(Data("type".utf8)); payload.append(word(code.rawValue))
        default:
            fatalError("The compatibility fixture only authors blob and type records")
        }
    }
    precondition(payload.count > 4_096 && payload.count + 8 <= 8_192)
    var data = Data(count: 16_388)
    func put(_ value: UInt32, at offset: Int) { data.replaceSubrange(offset..<(offset + 4), with: word(value)) }
    for (offset, value): (Int, UInt32) in [
        (0, 1), (4, 0x4275_6431), (8, 2_048), (12, 2_048), (16, 2_048),
        (36, 2), (40, 0), (44, UInt32(records.count)), (48, 1), (52, 4_096),
        (2_052, 3), (2_060, 0x080B), (2_064, 0x0025), (2_068, 0x200D),
        (3_084, 1), (3_093, 1), (8_196, 0), (8_200, UInt32(records.count)),
    ] { put(value, at: offset) }
    data[3_088] = 4
    data.replaceSubrange(3_089..<3_093, with: Data("DSDB".utf8))
    data.replaceSubrange(8_204..<(8_204 + payload.count), with: payload)
    // Fail generation if the independent allocation or sort order is invalid.
    let parsed = try DSStore.read(from: data)
    precondition(parsed.records.count == records.count)
    return data
}

var store = DSStore()
store.setViewStyle(.iconView)
try store.setWindowBounds(top: 100, left: 100, bottom: compatibility ? 480 : 378, right: compatibility ? 640 : 500)
store.setBackground(.picture(aliasData: alias(volume: compatibility ? "Compatibility Tool v8.0" : "Layout Tool v2.7.1",
                                            parent: compatibility ? "" : ".background", file: compatibility ? ".background.tiff" : "bg@2x.png")))
var settings = store.iconViewSettings()!
settings.iconSize = compatibility ? 80 : 96
settings.textSize = 12
settings.labelOnBottom = true
store.setIconViewSettings(settings)
try store.setIconPosition(for: compatibility ? "Compatibility Tool.app" : "Layout Tool.app", x: compatibility ? 130 : 100, y: compatibility ? 220 : 120)
try store.setIconPosition(for: "Applications", x: compatibility ? 410 : 300, y: compatibility ? 220 : 120)
if compatibility {
    guard let record = store.record(for: ".", type: .iconViewProperties),
          case .propertyList(.dictionary(var properties)) = record.value else { fatalError("Missing icon-view properties") }
    properties["stowFixturePadding"] = .data(Data(repeating: 0x42, count: 5_000))
    store.add(.init(filename: ".", type: .iconViewProperties, value: .propertyList(.dictionary(properties))))
    try largeLeafStore(store).write(to: out.appending(path: "DS_Store"))

    let destination = CGImageDestinationCreateWithURL(out.appending(path: ".background.tiff") as CFURL,
                                                     UTType.tiff.identifier as CFString, 2, nil)!
    for scale in [1, 2] {
        let background = image(width: 540 * scale, height: 380 * scale) { context in
            context.setFillColor(CGColor(srgbRed: 0.16, green: 0.24, blue: 0.32, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(540 * scale), height: CGFloat(380 * scale)))
        }
        CGImageDestinationAddImage(destination, background, nil)
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    let bookmark = try URL(filePath: "/Applications", directoryHint: .isDirectory)
        .bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: [.pathKey, .isDirectoryKey], relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: out.appending(path: "Applications"))
} else {
    try store.write(to: out.appending(path: "DS_Store"))
}
