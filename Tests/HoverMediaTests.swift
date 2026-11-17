import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Testing
@testable import Stow

/// #323: audio and video play inside hover previews.
@MainActor
@Suite("Hover media playback", .serialized)
struct HoverMediaTests {
    private func entry(_ name: String = "clip.mov") -> ArchiveEntry {
        ArchiveEntry(path: name, isFolder: false, size: 1, packedSize: 1, modified: .now)
    }

    /// Leaving the row for the card keeps it; leaving the card closes it after the usual grace.
    @Test func theCardHoldsItselfOpenWhileThePointerIsOnIt() async throws {
        let hover = HoverPreviewModel(mouseButtons: { 0 }, isDragging: { false })
        hover.present("clip.mov")
        hover.exit(entry())
        hover.holdOpen(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hover.presented == "clip.mov")
        hover.holdOpen(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hover.presented == nil)
    }

    /// Back onto a row from the card: that row's preview, as when scanning.
    @Test func returningToARowFromTheCardKeepsScanning() async throws {
        let hover = HoverPreviewModel(mouseButtons: { 0 }, isDragging: { false })
        hover.present("clip.mov")
        hover.holdOpen(false)
        hover.enter(entry("song.m4a"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(hover.presented == "song.m4a")
        hover.close()
    }

    @Test func pressesInTheCardDoNotCloseIt() async throws {
        let hover = HoverPreviewModel(mouseButtons: { 0 }, isDragging: { false })
        let card = NSWindow(), other = NSWindow()
        hover.present("clip.mov")
        hover.cardWindow = card
        #expect(!hover.interrupts(in: card))
        #expect(hover.interrupts(in: other))
        #expect(hover.interrupts(in: nil))
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: card.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(press)
        #expect(hover.presented == "clip.mov")
        let elsewhere = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: other.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(elsewhere)
        #expect(hover.presented == nil)
        // Closing forgets the card, so a stale window can't shield the next preview.
        #expect(hover.cardWindow == nil)
    }

    @Test func playableAudioCarriesItsFileAndBrokenAudioDoesNot() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let tone = try MediaFixture.tone(in: folder.url)
        guard case .audio(_, _, _, let duration, let media) = await PreviewService.read(tone, kind: .audio) else {
            Issue.record("not audio"); return
        }
        #expect(media == tone)
        #expect(abs((duration ?? 0) - 1) < 0.1)
        let broken = folder.url.appending(path: "broken.mp3")
        try Data("not audio".utf8).write(to: broken)
        if case .audio(_, _, _, _, let media) = await PreviewService.read(broken, kind: .audio) {
            #expect(media == nil)
        }
    }

    @Test func playableVideoCarriesItsFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let clip = try await MediaFixture.clip(in: folder.url)
        guard case .video(let frame, _, let media) = await PreviewService.read(clip, kind: .video) else {
            Issue.record("not video"); return
        }
        #expect(frame != nil)
        #expect(media == clip)
        // Sound only, under a movie's name: there is no picture to play in the card.
        let tone = try MediaFixture.tone(in: folder.url)
        let renamed = folder.url.appending(path: "tone.mov")
        try FileManager.default.copyItem(at: tone, to: renamed)
        if case .video(_, _, let media) = await PreviewService.read(renamed, kind: .video) { #expect(media == nil) }
    }

    /// Video starts muted and looping; audio waits for Play; taking the card away lets go of both.
    @Test(arguments: [HoverMediaPlayer.Kind.video, .audio])
    func thePlayerStartsAsDesignedAndIsReleased(kind: HoverMediaPlayer.Kind) async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let url = kind == .video ? try await MediaFixture.clip(in: folder.url) : try MediaFixture.tone(in: folder.url)
        let host = NSHostingView(rootView: AnyView(HoverMediaPlayer(url: url, kind: kind, startsPlaying: kind == .video)
            .frame(width: 300, height: 200)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // Owned here: AppKit's release-on-close would free it a second time.
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(Self.playerView(in: host))
        let player = try #require(view.player)
        #expect(view.controlsStyle == .inline)
        #expect(!view.showsFullScreenToggleButton)
        #expect(player.isMuted == (kind == .video))
        #expect(player.preventsDisplaySleepDuringVideoPlayback == false)
        #expect((player.rate > 0) == (kind == .video))
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        #expect(view.player == nil)
        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
        window.close()
    }

    private static func playerView(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        for child in view.subviews { if let found = playerView(in: child) { return found } }
        return nil
    }
}

/// Small media files made on the spot, so no fixture has to be checked in.
enum MediaFixture {
    /// One second of a 440 Hz tone as 16-bit WAV.
    static func tone(in folder: URL) throws -> URL {
        let url = folder.appending(path: "tone.wav")
        let rate = 44_100
        var samples = Data()
        for index in 0..<rate {
            var value = Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 8_000).littleEndian
            withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2)) + le(UInt16(16))
        wav += Data("data".utf8) + le(UInt32(samples.count)) + samples
        try wav.write(to: url)
        return url
    }

    /// Half a second of 64×48 H.264 frames in a QuickTime movie.
    static func clip(in folder: URL) async throws -> URL {
        let url = folder.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 16), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
