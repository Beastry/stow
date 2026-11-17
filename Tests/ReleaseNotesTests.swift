import Foundation
import Testing
@testable import Stow

struct ReleaseNotesTests {
    @Test func releaseBuildOpensItsOwnReleasePage() {
        #expect(ReleaseNotes.url(version: "0.1.7", isDebugBuild: false).absoluteString
                == "https://github.com/Beastry/stow/releases/tag/v0.1.7")
    }

    @Test func unpublishedBuildsOpenTheReleaseList() {
        #expect(ReleaseNotes.url(version: "0.1.7", isDebugBuild: true) == ReleaseNotes.allReleases)
        #expect(ReleaseNotes.url(version: nil, isDebugBuild: false) == ReleaseNotes.allReleases)
    }

    @Test(arguments: ["", "1", "1.", "1..2", "1.2-beta", "v1.2", "1.2/../..", "1.2?x=1", "１.２", "1.2.3.4.5"])
    func oddVersionsNeverReachTheURL(version: String) {
        #expect(ReleaseNotes.url(version: version, isDebugBuild: false) == ReleaseNotes.allReleases)
    }
}
