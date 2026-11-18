import Foundation

/// Where Help › Release Notes goes (#330): the GitHub release page for the version that is running,
/// the same page the update feed links (`scripts/generate-appcast.sh`). A build that was never
/// published has no page of its own, so it opens the list of releases instead.
nonisolated enum ReleaseNotes {
    static let allReleases = URL(string: "https://github.com/Beastry/stow/releases")!

    static func url(version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                    isDebugBuild: Bool = UpdatePolicy.isDebugBuild) -> URL {
        guard !isDebugBuild, let version, isReleaseVersion(version) else { return allReleases }
        return allReleases.appending(path: "tag/v\(version)")
    }

    /// Dotted numbers only ("0.1.7"): anything else never names a release tag.
    static func isReleaseVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}
