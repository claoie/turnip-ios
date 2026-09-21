import AVFoundation
import SwiftUI

/// A thin playback bar for a bare `AVPlayer` surface: play/pause, a draggable scrub
/// track, and a mute toggle. Pairs with `BareVideoPlayerView`, which has no transport
/// controls of its own (`docs/UIUX.md` § "Processing").
struct VideoScrubBar: View {
    let player: AVPlayer

    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var duration: TimeInterval = 0
    @State private var currentTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    private static let trackHeight: CGFloat = 3

    var body: some View {
        PlaybackControlsPill {
            HStack(spacing: 12) {
                PlayPauseButton(isPlaying: isPlaying, action: togglePlayback)
                track
                    .frame(height: Self.trackHeight)
                MuteButton(isMuted: isMuted, action: toggleMute)
            }
        }
        .task { attach() }
        .onDisappear { detach() }
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: width * fraction)
            }
            .contentShape(Rectangle().inset(by: -10)) // Widens the drag target past the thin visual track.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let scrubbedFraction = min(max(value.location.x / width, 0), 1)
                        currentTime = scrubbedFraction * duration
                        seek(to: currentTime)
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
    }

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { player.play() } else { player.pause() }
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attach() {
        isMuted = player.isMuted
        isPlaying = player.rate != 0
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            // Duration isn't known until the item loads, so this polls it alongside
            // the current time rather than watching `currentItem.status` separately.
            let seconds = player.currentItem?.duration.seconds ?? 0
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            guard !isScrubbing else { return }
            currentTime = time.seconds
        }
    }

    private func detach() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}
