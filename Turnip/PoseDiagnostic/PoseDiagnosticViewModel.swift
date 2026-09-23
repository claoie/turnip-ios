import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class PoseDiagnosticViewModel: ObservableObject {
    @Published private(set) var results: [PoseFrameResult] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?
    /// The frame size as the player shows it (display orientation); nil until `prepare` loads
    /// it. The sampler renders frames into this same size, so the frame-normalized keypoints
    /// map onto the player by a plain multiply once the player stack has this aspect ratio.
    @Published private(set) var displaySize: CGSize?
    @Published private(set) var playbackTime: TimeInterval = 0
    /// What a live-inference recording measured, when this screen is reviewing one; nil for a
    /// plain post-hoc run. Kept through a later "Run diagnostic" so the two can be compared.
    @Published private(set) var liveMetrics: LivePoseMetrics?
    /// The recording's frame-count audit, loaded alongside `liveMetrics`.
    @Published private(set) var fileAudit: LivePoseFileAudit?

    /// Created up front so `VideoPlayer` never sees a nil player; the item is attached in
    /// `prepare`.
    let player = AVPlayer()

    private let sampler = VideoFrameSampler()
    private var runTask: Task<Void, Never>?
    private var auditTask: Task<Void, Never>?
    private var timeObserver: Any?

    /// Popping the screen has to stop the run. Without this a swipe-back would leave a full decode
    /// plus per-frame inference burning the device with no consumer, and every back-and-tap would
    /// stack another one against the same cooperative pool.
    deinit {
        runTask?.cancel()
        auditTask?.cancel()
    }

    var summary: PoseDiagnosticSummary? {
        results.isEmpty ? nil : PoseDiagnosticSummary(results: results)
    }

    /// The sampled frame closest to the playhead — what the overlay draws and the list highlights.
    var currentResult: PoseFrameResult? {
        Self.nearestResult(to: playbackTime, in: results)
    }

    /// Attaches the video to the player and loads its displayed size. Called from the view's
    /// `.task`; safe to call again — re-appearing re-arms the time observer `teardown` dropped.
    func prepare(with asset: AVURLAsset) async {
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        }
        if timeObserver == nil {
            let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor in
                    self?.playbackTime = time.seconds
                }
            }
        }
        guard displaySize == nil,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform)
        else { return }
        displaySize = Self.displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
    }

    /// Stops playback and drops the time observer. Called when the view disappears.
    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    /// Pauses on the exact frame a row describes, so its numbers can be checked against the
    /// picture. Zero tolerance: the row's timestamp is a grid position the sampler emitted, and
    /// a nearby keyframe would show a different frame than the one that was scored.
    func seek(to result: PoseFrameResult) {
        player.pause()
        player.seek(
            to: CMTime(seconds: result.timestamp, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = result.timestamp
    }

    /// Shows what a live-inference recording produced (docs/LIVE_POSE.md) and audits the written
    /// file's frame count against its duration. "Run diagnostic" stays available on the same
    /// file as the post-hoc baseline the acceptance gate compares against; the live metrics stay
    /// on screen when it replaces the rows. Idempotent so a re-appearing view does not undo a
    /// baseline run.
    func adoptLive(_ outcome: LivePoseOutcome, asset: AVURLAsset) {
        guard liveMetrics == nil else { return }
        results = outcome.results
        liveMetrics = outcome.metrics
        errorMessage = outcome.errorMessage
        auditTask = Task { [weak self] in
            do {
                let audit = try await LivePoseFileAudit.audit(asset)
                self?.fileAudit = audit
            } catch is CancellationError {
                // The screen went away; nobody is waiting for the count.
            } catch let error as PoseError {
                self?.errorMessage = error.errorDescription
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs MoveNet Thunder over `asset`, the video Home resolved from the tapped tile (see
    /// `SelectedVideo`). Temp-file lifetime for composition exports is owned by
    /// `VideoLibraryViewModel.path`, not by this screen — a back-out without a run still cleans up.
    func runDiagnostic(on asset: AVURLAsset) {
        guard !isRunning else { return }
        results = []
        errorMessage = nil
        isRunning = true

        // `weak self` is what makes `deinit` reachable at all: a strong capture would keep this
        // view model alive for as long as the run it is supposed to be cancelled by.
        runTask = Task { [weak self, sampler] in
            defer { self?.isRunning = false }
            do {
                let model = try await MoveNetThunderModel.load()
                try await sampler.sampleFrames(from: asset) { frame in
                    let keypoints = try await model.runInference(on: frame.pixelBuffer)
                    let result = PoseFrameResult(
                        frameIndex: frame.frameIndex,
                        timestamp: frame.timestamp,
                        keypoints: keypoints
                    )
                    PoseResultLogger.log(result)
                    await MainActor.run {
                        self?.results.append(result)
                    }
                }
            } catch is CancellationError {
                // The screen went away mid-run; there is nobody left to tell.
            } catch let error as PoseError {
                self?.errorMessage = error.errorDescription
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// The result whose timestamp is closest to `time`. `results` must be in timestamp order,
    /// which the sampler guarantees by emitting frames in decode order; ties go to the later
    /// frame. Pure so the playhead-to-row mapping is unit-testable.
    nonisolated static func nearestResult(to time: TimeInterval, in results: [PoseFrameResult]) -> PoseFrameResult? {
        guard !results.isEmpty else { return nil }
        var low = 0
        var high = results.count - 1
        while low < high {
            let mid = (low + high) / 2
            if results[mid].timestamp < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        // `low` is the first result at or after `time`; the one before it may be closer.
        if low > 0, time - results[low - 1].timestamp < results[low].timestamp - time {
            return results[low - 1]
        }
        return results[low]
    }

    /// The frame size as the player shows it: the encoded size through `preferredTransform`,
    /// so a 90°-rotated track reports portrait dimensions. The same computation
    /// `VideoFrameSampler` uses for its render size, which is what makes the two spaces agree.
    nonisolated static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
