import CoreGraphics
import DSStore
import Foundation
import Testing
@testable import Stow

@Suite("Installer store compatibility")
struct InstallerStoreCompatibilityTests {
    /// Finder's logical page size can remain 4096 while the allocator gives a leaf more room.
    /// This synthetic layout includes a record that actually extends past the first page.
    @Test(arguments: [8_192, 16_384])
    func readsLargerLeafAllocations(nodeSize: Int) throws {
        let data = store(nodeSize: nodeSize)
        let parsed = try DSStore.read(from: data)
        #expect(parsed.records.count == 3)
        #expect(parsed.iconPosition(for: "OpenWhispr.app")?.x == 130)
        #expect(parsed.iconPosition(for: "Applications")?.x == 410)
        let layout = try #require(InstallerLayout.read(data))
        #expect(layout.positions == ["OpenWhispr.app": CGPoint(x: 130, y: 220),
                                     "Applications": CGPoint(x: 410, y: 220)])
    }

    @Test func rejectsTruncatedAndOutOfBoundsLargeNodes() {
        let valid = store()
        #expect(InstallerLayout.read(Data(valid.dropLast())) == nil)

        var outOfBounds = valid
        put(0x8000_001F, in: &outOfBounds, at: addressOffset)
        #expect(InstallerLayout.read(outOfBounds) == nil)

        var misaligned = valid
        put(0x202D, in: &misaligned, at: addressOffset)
        #expect(InstallerLayout.read(misaligned) == nil)
    }

    @Test func rejectsRecordsBeyondTheAllocationAndCountMismatches() {
        var recordTooLarge = store()
        // The first record's blob length, after its UTF-16 name, record type and value type.
        put(0x20_000, in: &recordTooLarge, at: nodeOffset + 22)
        #expect(InstallerLayout.read(recordTooLarge) == nil)

        var wrongCount = store()
        put(4, in: &wrongCount, at: 44)
        #expect(InstallerLayout.read(wrongCount) == nil)

        var wrongPageSize = store()
        put(8_192, in: &wrongPageSize, at: 52)
        #expect(InstallerLayout.read(wrongPageSize) == nil)
    }

    @Test func rejectsLargeNodesThatReferBackToThemselves() {
        var cyclic = store()
        put(1, in: &cyclic, at: 40) // One internal level.
        put(2, in: &cyclic, at: nodeOffset) // Rightmost child refers to this node.
        put(1, in: &cyclic, at: nodeOffset + 4)
        put(2, in: &cyclic, at: nodeOffset + 8) // First child also refers to this node.
        #expect(InstallerLayout.read(cyclic) == nil)
    }

    @Test func installerInputLimitStillApplies() {
        #expect(InstallerLayout.read(Data(count: InstallerLayout.maxStoreBytes + 1)) == nil)
    }

    private let nodeOffset = 8_196
    private let addressOffset = 2_068

    /// An independent, minimal Buddy/DSDB file with one allocated leaf; no third-party bytes.
    private func store(nodeSize: Int = 8_192) -> Data {
        var data = Data(count: nodeSize * 2 + 4)
        for (offset, value): (Int, UInt32) in [
            (0, 1), (4, 0x4275_6431), (8, 2_048), (12, 2_048), (16, 2_048),
            (36, 2), (40, 0), (44, 3), (48, 1), (52, 4_096),
            (2_052, 3), (2_060, 0x080B), (2_064, 0x0025),
            (addressOffset, UInt32(nodeSize) | UInt32(nodeSize.trailingZeroBitCount)),
            (3_084, 1), // TOC follows 256 allocator addresses.
            (3_093, 1), // DSDB points to block 1.
            (nodeSize + 4, 0), (nodeSize + 8, 3),
        ] {
            put(value, in: &data, at: offset)
        }
        data[3_088] = 4
        data.replaceSubrange(3_089..<3_093, with: Data("DSDB".utf8))

        var records = record(name: ".", type: "pBBk", blob: Data(repeating: 0x42, count: 5_000))
        for (name, x) in [("Applications", 410), ("OpenWhispr.app", 130)] {
            var position = Data(count: 16)
            put(UInt32(x), in: &position, at: 0)
            put(220, in: &position, at: 4)
            records.append(record(name: name, type: "Iloc", blob: position))
        }
        data.replaceSubrange((nodeSize + 12)..<(nodeSize + 12 + records.count), with: records)
        return data
    }

    private func record(name: String, type: String, blob: Data) -> Data {
        var data = Data(count: 4)
        put(UInt32(name.utf16.count), in: &data, at: 0)
        data.append(name.data(using: .utf16BigEndian)!)
        data.append(Data(type.utf8))
        data.append(Data("blob".utf8))
        var length = Data(count: 4)
        put(UInt32(blob.count), in: &length, at: 0)
        data.append(length)
        data.append(blob)
        return data
    }

    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
                                                        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
