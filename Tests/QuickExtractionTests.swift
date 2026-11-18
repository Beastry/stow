import Foundation
import Testing
@testable import Stow

/// #328: Settings › Extraction › Double-click in Finder extracts.
struct QuickExtractionTests {
    let zip = URL(fileURLWithPath: "/tmp/a/Photos.zip")
    let rar = URL(fileURLWithPath: "/tmp/a/Old.rar")
    let dmg = URL(fileURLWithPath: "/tmp/a/Installer.dmg")
    let iso = URL(fileURLWithPath: "/tmp/a/Disc.iso")
    let pkg = URL(fileURLWithPath: "/tmp/a/Setup.pkg")
    let exe = URL(fileURLWithPath: "/tmp/a/Tool.exe")
    let finder = QuickExtraction.Origin(sender: QuickExtraction.finder)

    @Test func offByDefaultAndReset() throws {
        #expect(!Preferences.defaults.quickExtractOnOpen)
        let name = "quick-extract-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        #expect(!Preferences.values(in: store).quickExtractOnOpen)
        store.set(true, forKey: Preferences.Key.quickExtractOnOpen)
        #expect(Preferences.values(in: store).quickExtractOnOpen)
        #expect(SettingsKeys.resettableEntries(for: .extraction).map(\.key).contains(Preferences.Key.quickExtractOnOpen))
        SettingsKeys.reset(in: store)
        #expect(!Preferences.values(in: store).quickExtractOnOpen)
    }

    @Test func finderOpensExtractWhenOn() {
        let route = QuickExtraction.route([zip, rar], enabled: true, origin: finder) { _ in false }
        #expect(route.extract == [zip, rar])
        #expect(route.open.isEmpty)
    }

    @Test func offOrUnknownOriginOpensAsBefore() {
        #expect(QuickExtraction.route([zip], enabled: false, origin: finder) { _ in false }.open == [zip])
        #expect(QuickExtraction.route([zip], enabled: true, origin: nil) { _ in false }.open == [zip])
        #expect(QuickExtraction.route([zip], enabled: true, origin: .init(sender: nil)) { _ in false }.open == [zip])
    }

    /// Quick Look's Open in Stow, the Dock, other apps and `open` all browse: the file may sit in
    /// another app's container. A process that only names itself by PID counts as unknown.
    @Test(arguments: ["app.stow.Stow.QuickLook", "com.apple.quicklook.QuickLookUIService", "com.apple.dock",
                      "com.apple.mail", "com.tencent.xinWeChat", "com.apple.Safari", "pid 4242", "com.apple.finder.extra"])
    func otherSendersBrowse(sender: String) {
        let route = QuickExtraction.route([zip], enabled: true, origin: .init(sender: sender)) { _ in false }
        #expect(route.extract.isEmpty && route.open == [zip])
    }

    @Test func shiftBrowses() {
        let origin = QuickExtraction.Origin(sender: QuickExtraction.finder, browseHeld: true)
        #expect(QuickExtraction.route([zip], enabled: true, origin: origin) { _ in false }.open == [zip])
    }

    /// Disk images, installer packages and files Stow doesn't list as archives open; the rest of
    /// the same double-click still extracts, in order.
    @Test func exceptionsOpenAndTheRestExtract() {
        let route = QuickExtraction.route([dmg, zip, iso, pkg, exe, rar], enabled: true, origin: finder) { _ in false }
        #expect(route.extract == [zip, rar])
        #expect(route.open == [dmg, iso, pkg, exe])
        for url in ["a.wim", "a.vhd"].map({ URL(fileURLWithPath: "/tmp/\($0)") }) { #expect(!QuickExtraction.extracts(url)) }
        for url in ["a.7z", "a.tar.gz", "a.tgz", "a.cbz", "a.001", "a.xar", "a.jar"].map({ URL(fileURLWithPath: "/tmp/\($0)") }) {
            #expect(QuickExtraction.extracts(url))
        }
        #expect(!QuickExtraction.extracts(URL(string: "https://example.com/a.zip")!))
    }

    @Test func anOpenArchiveComesForwardInstead() {
        let route = QuickExtraction.route([zip, rar], enabled: true, origin: finder) { $0 == zip }
        #expect(route.extract == [rar])
        #expect(route.open == [zip])
    }

    @Test func neverAsksAfterwards() {
        #expect(QuickExtraction.afterwards(.keep) == .keep)
        #expect(QuickExtraction.afterwards(.ask) == .keep)
        #expect(QuickExtraction.afterwards(.trash) == .trash)
    }
}
