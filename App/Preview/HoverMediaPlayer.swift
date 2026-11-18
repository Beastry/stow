import AVFoundation
import AVKit
import SwiftUI

/// Playback inside a hover card (#323), with AVKit's own inline controls: play and pause, the
/// scrubber for seeking, volume. A video starts at once, muted and looping, the way a glance at
/// a clip should behave; sound is one click on the volume control away. Audio waits for Play,
/// since sound nobody asked for is never a glance. Under Reduce Motion a video waits too, and
/// turning Reduce Motion on while a card is open pauses its video.
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
        /// The `startsPlaying` last applied, so only a change of it (Reduce Motion switched while
        /// the card is open) touches playback, never an unrelated SwiftUI update.
        var startsPlaying = false
        /// Automatic playback is being held back (by Reduce Motion, or audio waiting for Play).
        /// Pressing Play ends the hold: the person's own choice is never undone or redone.
        var holdsAutoplay = false
        var playing: NSKeyValueObservation?

        func apply(startsPlaying: Bool) {
            guard startsPlaying != self.startsPlaying, let player else { return }
            self.startsPlaying = startsPlaying
            if startsPlaying {
                // Reduce Motion off again: back to the glance's own playback, unless the person
                // has taken over since.
                guard holdsAutoplay else { return }
                holdsAutoplay = false
                player.play()
            } else {
                // A video the person already paused stays theirs: no resume when this flips back.
                holdsAutoplay = player.rate != 0
                player.pause()
            }
        }

        /// Play pressed while automatic playback is held: from here on playback is theirs.
        /// Changes may arrive off the main thread; the rate is read again once there.
        func watch(_ player: AVPlayer) {
            playing = player.observe(\.rate) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, self.holdsAutoplay, let player = self.player, player.rate != 0 else { return }
                    self.holdsAutoplay = false
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        // The card already gives the player the clip's own shape (from its still), so filling it
        // only trims rounding: fitting left a hairline of the player's black background showing.
        view.videoGravity = poster == nil ? .resizeAspect : .resizeAspectFill
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
            still.imageScaling = .scaleAxesIndependently
            still.frame = overlay.bounds
            still.autoresizingMask = [.width, .height]
            overlay.addSubview(still)
            context.coordinator.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { [weak still] time in
                if time.seconds > 0.05 { still?.isHidden = true }
            }
        }
        context.coordinator.startsPlaying = startsPlaying
        context.coordinator.holdsAutoplay = !startsPlaying
        if startsPlaying { player.play() }
        context.coordinator.watch(player)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.apply(startsPlaying: startsPlaying)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        if let observer = coordinator.timeObserver { coordinator.player?.removeTimeObserver(observer) }
        coordinator.timeObserver = nil
        coordinator.playing?.invalidate()
        coordinator.playing = nil
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        coordinator.player?.removeAllItems()
        view.player = nil
        coordinator.looper = nil
        coordinator.player = nil
    }
}
