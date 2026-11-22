#!/usr/bin/env swift
import Foundation

// Run from the project root. Grant the sandboxed test host access to disposable fixtures only.
let manager = FileManager.default
let home = manager.homeDirectoryForCurrentUser
var fixtures: [URL] = []
do {
    defer {
        for url in fixtures {
            do { try manager.removeItem(at: url) }
            catch { FileHandle.standardError.write(Data("Clean up \(url.path): \(error)\n".utf8)) }
        }
    }
    var bookmarks: [String: Data] = [:]
    for path in ["Desktop", "Documents", "Library/Mobile Documents/com~apple~CloudDocs"] {
        let location = home.appending(path: path)
        guard manager.isUbiquitousItem(at: location) else {
            throw NSError(domain: "StowCloudTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(path) is not cloud-backed"])
        }
        let url = location.appending(path: "Stow-Cloud-Test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        fixtures.append(url)
        try url.lastPathComponent.write(to: url.appending(path: ".fixture-id"), atomically: true, encoding: .utf8)
        bookmarks[url.lastPathComponent] = try url.bookmarkData()
    }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcodebuild")
    process.arguments = ["-project", "Stow.xcodeproj", "-scheme", "Stow", "-derivedDataPath", CommandLine.arguments.dropFirst().first ?? "build",
                         "-parallel-testing-enabled", "NO", "-only-testing:StowTests/CloudPublicationTests", "test"]
    var environment = ProcessInfo.processInfo.environment
    environment["TEST_RUNNER_STOW_CLOUD_FIXTURES"] = String(decoding: try JSONEncoder().encode(bookmarks), as: UTF8.self)
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "xcodebuild", code: Int(process.terminationStatus)) }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
