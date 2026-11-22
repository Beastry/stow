#!/usr/bin/env swift
import Foundation

struct Destination: Codable {
    let name: String
    let bookmark: Data
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: scripts/check-archive-benchmark-volume.swift /Volumes/Volume /path/to/built-derived-data\n".utf8))
    exit(2)
}
let manager = FileManager.default
let volume = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory).resolvingSymlinksInPath()
let build = CommandLine.arguments[2]
let name = "Stow-Benchmark-\(UUID().uuidString)"
let folder = volume.appending(path: name, directoryHint: .isDirectory)
let marker = folder.appending(path: ".fixture-id")
try manager.createDirectory(at: folder, withIntermediateDirectories: false)
do {
    try name.write(to: marker, atomically: true, encoding: .utf8)
    let destination = Destination(name: name, bookmark: try folder.bookmarkData())
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    let staging = manager.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/app.stow.Stow.Engine/Data/tmp/StowEngineStaging")
    process.arguments = ["python3", "scripts/sample-archive-benchmark.py", "--build", build,
                         "--staging", staging.path, "--", "/usr/bin/xcodebuild",
                         "-project", "Stow.xcodeproj", "-scheme", "Stow", "-destination", "platform=macOS,arch=arm64",
                         "-derivedDataPath", build, "-parallel-testing-enabled", "NO",
                         "-only-testing:StowTests/ArchivePerformanceTests", "test-without-building"]
    var environment = ProcessInfo.processInfo.environment
    environment["TEST_RUNNER_STOW_BENCHMARK_DESTINATION"] = String(decoding: try JSONEncoder().encode(destination), as: UTF8.self)
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "xcodebuild", code: Int(process.terminationStatus))
    }
    let remaining = try manager.contentsOfDirectory(atPath: folder.path)
    guard remaining == [".fixture-id"] else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Benchmark test left files in its fixture directory"])
    }
    try manager.removeItem(at: marker)
    try manager.removeItem(at: folder)
    print("STOW_BENCHMARK physical-volume-cleanup verified")
} catch {
    try? manager.removeItem(at: folder)
    throw error
}
