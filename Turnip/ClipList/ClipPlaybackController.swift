import AVFoundation
import Foundation

/// Drives inline clip playback for one context — the grid's tiles, or the expanded
/// full-screen pager — over a single shared `AVPlayer`. At most one clip plays at a
/// time within a context: tapping a different tile stops whichever clip was playing
/// rather than starting a second decoder, so a grid of tiles never runs multiple
/// simultaneous decodes.
@MainActor
final class ClipPlaybackController: ObservableObject {
    @Published private(set) var activeItemID: UUID?
    @Published private(set) var isPlaying = false

    private let asset: AVAsset
    private(set) var player: AVPlayer?
    private var endObserver: Any?
    /// True while an exact seek is in flight. AVFoundation queues overlapping exact
    /// seeks internally, so issuing one per drag update makes the preview lag well
    /// behind the finger; coalescing (below) keeps every seek exact while staying
    /// responsive.
    private var isSeeking = false
    /// The most recent time requested while a seek is in flight — applied as soon as
    /// the current seek completes, so the preview always catches up to exactly where
    /// the finger is now rather than working through every intermediate frame.
    private var pendingSeekTime: TimeInterval?

    init(asset: AVAsset) {
        self.asset = asset
    }

    /// The tile tap: starts this clip playing (looping the window, like the old
    /// full-screen player did) if it wasn't the active one, or pauses it if it was.
    func toggle(_ item: ClipListItem) {
        if activeItemID == item.id {
            if isPlaying {
                pause()
            } else {
                resume(item)
            }
        } else {
            play(item)
        }
    }

    /// Shows `item` paused at `time` — the trim handles' live preview while dragging,
    /// or the frame a page settles on when it first appears. Reuses the current player
    /// via `replaceCurrentItem` rather than spinning up a fresh decoder on every call.
    /// Always exact (never tolerant): see `seekCoalesced` for how it stays responsive
    /// at drag frequency without trading away precision.
    func preview(_ item: ClipListItem, at time: TimeInterval) {
        if activeItemID != item.id {
            clearBoundary()
            let player = self.player ?? makePlayer()
            self.player = player
            player.replaceCurrentItem(with: AVPlayerItem(sdrAsset: asset))
            activeItemID = item.id
            isSeeking = false
            pendingSeekTime = nil
        }
        player?.pause()
        isPlaying = false
        seekCoalesced(to: time)
    }

    /// Leaves the clip on the frame the last preview or pause left it at — the card
    /// keeps showing that frame instead of reverting to its static thumbnail.
    func stop() {
        clearBoundary()
        player?.pause()
        isPlaying = false
    }

    private func play(_ item: ClipListItem) {
        clearBoundary()
        let player = self.player ?? makePlayer()
        self.player = player
        player.replaceCurrentItem(with: AVPlayerItem(sdrAsset: asset))
        activeItemID = item.id
        seek(to: item.window.startTime)
        armBoundary(at: item.window.endTime)
        player.play()
        isPlaying = true
    }

    private func resume(_ item: ClipListItem) {
        guard let player else { return }
        if player.currentTime().seconds >= item.window.endTime {
            seek(to: item.window.startTime)
        }
        armBoundary(at: item.window.endTime)
        player.play()
        isPlaying = true
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    private func makePlayer() -> AVPlayer {
        AVPlayer()
    }

    private func seek(to time: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Issues an exact seek if none is in flight; otherwise just records `time` as the
    /// next target. When the in-flight seek's completion handler fires, it immediately
    /// issues one more exact seek to the latest pending time (if any), so a burst of
    /// drag updates collapses into "however many exact seeks the decoder can actually
    /// keep up with, always ending on the finger's current position" instead of queuing
    /// every intermediate frame behind the others.
    private func seekCoalesced(to time: TimeInterval) {
        guard let player else { return }
        guard !isSeeking else {
            pendingSeekTime = time
            return
        }
        isSeeking = true
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if let next = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.seekCoalesced(to: next)
                }
            }
        }
    }

    private func armBoundary(at endTime: TimeInterval) {
        clearBoundary()
        guard let player else { return }
        endObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: endTime, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            // The callback is a plain (non-isolated) closure even though it always
            // fires on the main queue, so `self` — `@MainActor` — needs the hop.
            Task { @MainActor in self?.pause() }
        }
    }

    private func clearBoundary() {
        if let endObserver, let player {
            player.removeTimeObserver(endObserver)
        }
        endObserver = nil
    }
}
