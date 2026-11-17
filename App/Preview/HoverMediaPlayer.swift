import AVFoundation
import AVKit
import SwiftUI

/// Playback inside a hover card (#323), with AVKit's own inline controls: play and pause, the
/// scrubber for seeking, volume. A video starts at once, muted and looping, the way a glance at
/// a clip should behave; sound is one click on the volume control away. Audio waits for Play,
/// since sound nobody asked for is never a glance. Under Reduce Motion a video waits too.
///
/// The player lives exactly as long as the card: closing it (any press elsewhere, the pointer
/// leaving, another file, the archive closing) stops playback and lets the file go.
struct HoverMediaPlayer: NSViewRepresentable {
    enum Kind { case audio, video }

    let url: URL
    let kind: Kind
    let startsPlaying: Bool
    /// The still the card already showed (#323). It stays, under the controls, until the video
    /// has actually moved, so the card never flashes black while the player warms up.
    var poster: NSImage? = nil

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var timeObserver: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        view.setAccessibilityLabel(kind == .audio ? String(localized: "Audio player") : String(localized: "Video player"))
        let player = AVQueuePlayer()
        // A hover glance never keeps the display awake, and never plays anywhere but here.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        let item = AVPlayerItem(url: url)
        if kind == .video {
            player.isMuted = true
            context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        context.coordinator.player = player
        view.player = player
        if let poster, kind == .video, let overlay = view.contentOverlayView {
            let still = NSImageView(image: poster)
            still.imageScaling = .scaleProportionallyUpOrDown
            still.frame = overlay.bounds
            still.autoresizingMask = [.width, .height]
            overlay.addSubview(still)
            context.coordinator.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { [weak still] time in
                if time.seconds > 0.05 { still?.isHidden = true }
            }
        }
        if startsPlaying { player.play() }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        if let observer = coordinator.timeObserver { coordinator.player?.removeTimeObserver(observer) }
        coordinator.timeObserver = nil
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        coordinator.player?.removeAllItems()
        view.player = nil
        coordinator.looper = nil
        coordinator.player = nil
    }
}
