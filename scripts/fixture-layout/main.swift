// Writes the authored-window assets for Tests/Fixtures/Fixture-Layout.dmg (#344): a `.DS_Store`
// with icon positions, icon/text sizes and a picture background whose Carbon Alias points at
// `/.background/bg@2x.png`, the 2x artwork itself, and a 512 px app icon picture.
//
// scripts/make-fixtures.sh compiles this together with the DSStore package's sources (resolved by
// Xcode under DerivedData/…/SourcePackages/checkouts/DSStore) and runs it into a work folder.
// Usage: make-layout <output folder>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)

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
    tag(18, Array("/\(parent)/\(file)".utf8))
    tag(-1, [])
    data[4] = UInt8(data.count >> 8)
    data[5] = UInt8(data.count & 0xFF)
    return data
}

func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
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

var store = DSStore()
store.setViewStyle(.iconView)
try store.setWindowBounds(top: 100, left: 100, bottom: 378, right: 500)
store.setBackground(.picture(aliasData: alias(volume: "Layout Tool v2.7.1", parent: ".background", file: "bg@2x.png")))
var settings = store.iconViewSettings()!
settings.iconSize = 96
settings.textSize = 12
settings.labelOnBottom = true
store.setIconViewSettings(settings)
try store.setIconPosition(for: "Layout Tool.app", x: 100, y: 120)
try store.setIconPosition(for: "Applications", x: 300, y: 120)
try store.write(to: out.appending(path: "DS_Store"))
