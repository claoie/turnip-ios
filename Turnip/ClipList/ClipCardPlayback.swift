import AVFoundation
import Combine
import Foundation
import UIKit

/// One tile's inline loop, behind a protocol so the lifecycle driving it is reachable
/// without a decoder: `AVPlayerLoop` is the real thing, tests inject a fake.
protocol ClipLooping: AnyObject {
    /// The player the tile's video layer renders.
    var player: AVQueuePlayer { get }
    func play()
    func pause()
    /// Releases the loop and the decode pipeline behind it. Not reusable afterwards —
    /// a later start builds a fresh loop.
    func stop()
}

/// Loops one window of an asset forever and muted, which needs an `AVQueuePlayer`
/// rather than a plain `AVPlayer`: `AVPlayerLooper` drives the repeat by keeping a
/// queue topped up with copies of its template item.
final class AVPlayerLoop: ClipLooping {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(asset: AVAsset, window: TrickWindow) {
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        player = queuePlayer
        looper = AVPlayerLooper(
            player: queuePlayer,
            templateItem: AVPlayerItem(sdrAsset: asset),
            timeRange: CMTimeRange(
                start: CMTime(seconds: window.startTime, preferredTimescale: 600),
                end: CMTime(seconds: window.endTime, preferredTimescale: 600)))
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}

/// The playback lifecycle of one Clip List tile: builds the tile's loop when it should
/// be running, pauses it while the editor covers the grid, releases it when the tile
/// scrolls away, and rebuilds it over the new range when an editor commit changes the
/// window.
///
/// A reference type outside the view rather than `@State` on it, for two reasons. The
/// system video-autoplay read and the loop construction become injectable, which is what
/// makes the accessibility fallback and the window-change rebuild assertable at all. And
/// the suspension flag and the window read live: SwiftUI can invoke an `.onChange(of:)`
/// action closure with a `self` captured from an earlier render than the one that produced
/// the new value, so the same state read off the view is stale from inside that closure —
/// observed as every tile bailing out of resume with suspension still set right after the
/// editor reported it clear, and as a resume after an editor commit rebuilding over the
/// pre-edit range.
@MainActor
final class ClipCardPlayback: ObservableObject {
    /// Builds a loop over `window` of `asset`.
    typealias MakeLoop = @MainActor (_ asset: AVAsset, _ window: TrickWindow) -> any ClipLooping

    /// The mounted loop, or `nil` when the tile has none — it then shows only its
    /// static poster thumbnail.
    @Published private(set) var loop: (any ClipLooping)?

    private let asset: AVAsset
    private let isAutoplayEnabled: @MainActor () -> Bool
    private let makeLoop: MakeLoop
    private var isSuspended = false
    private var window: TrickWindow?

    init(
        asset: AVAsset,
        isAutoplayEnabled: @escaping @MainActor () -> Bool = { UIAccessibility.isVideoAutoplayEnabled },
        makeLoop: @escaping MakeLoop = { AVPlayerLoop(asset: $0, window: $1) }
    ) {
        self.asset = asset
        self.isAutoplayEnabled = isAutoplayEnabled
        self.makeLoop = makeLoop
    }

    /// Adopts the tile's current window and suspension state, then starts its loop. Safe
    /// to call repeatedly — an already-built loop is just resumed.
    func start(window: TrickWindow, isSuspended: Bool) {
        self.window = window
        self.isSuspended = isSuspended
        resume()
    }

    /// Releases the tile's decoder entirely rather than just pausing, so a tile scrolled
    /// far off-screen doesn't keep a decode pipeline open behind ones that are visible.
    func teardown() {
        loop?.stop()
        loop = nil
    }

    /// Pauses while the editor covers the grid, and resumes when it closes. A pause keeps
    /// the loop mounted: the tile is still on screen and comes straight back.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            loop?.pause()
        } else {
            resume()
        }
    }

    /// Rebuilds the loop over `window`. The grid keys its tiles by clip id, so an editor
    /// commit that changes the window reuses this same tile — and, without the rebuild,
    /// its loop would keep playing the pre-edit range forever.
    func windowChanged(to window: TrickWindow) {
        self.window = window
        teardown()
        resume()
    }

    /// The single gate on playback: the system's video-autoplay setting being off rules
    /// out auto-playing loops entirely (`docs/ACCESSIBILITY.md`'s Clip List checklist —
    /// the tile shows its static poster instead), and a covered grid shouldn't be
    /// decoding behind the editor.
    private func resume() {
        guard let window, isAutoplayEnabled(), !isSuspended else { return }
        if loop == nil {
            loop = makeLoop(asset, window)
        }
        loop?.play()
    }
}
