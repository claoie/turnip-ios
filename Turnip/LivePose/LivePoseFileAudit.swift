import AVFoundation
import Foundation

/// Answers the acceptance gate's first question — did the recording drop frames? — from the
/// written file. `AVCaptureMovieFileOutput` reports no drops of its own, so the file's video track
/// is read straight through without decoding and its sample count compared against
/// duration × nominal frame rate.
struct LivePoseFileAudit: Equatable, Sendable {
    let sampleCount: Int
    let expectedSampleCount: Int
    let duration: TimeInterval
    let nominalFrameRate: Float

    var missingSamples: Int {
        max(expectedSampleCount - sampleCount, 0)
    }

    /// "File: 43,205 samples, 43,200 expected at 240 fps over 180.0 s".
    var summaryLine: String {
        "File: \(sampleCount) samples, \(expectedSampleCount) expected at "
            + "\(String(format: "%.0f", nominalFrameRate)) fps over \(String(format: "%.1f", duration)) s"
    }

    static func expectedSampleCount(duration: TimeInterval, nominalFrameRate: Float) -> Int {
        Int((duration * Double(nominalFrameRate)).rounded())
    }

    /// Reads every video sample of `asset` (passthrough, no decode) and counts them.
    static func audit(_ asset: AVURLAsset) async throws -> LivePoseFileAudit {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        let timeRange = try await track.load(.timeRange)
        let nominalFrameRate = try await track.load(.nominalFrameRate)

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(trackOutput) else {
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw PoseError.videoLoadFailed(underlying: reader.error)
        }

        var sampleCount = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            sampleCount += CMSampleBufferGetNumSamples(sampleBuffer)
        }
        if reader.status == .failed {
            throw PoseError.videoLoadFailed(underlying: reader.error)
        }

        let duration = timeRange.duration.seconds
        return LivePoseFileAudit(
            sampleCount: sampleCount,
            expectedSampleCount: expectedSampleCount(duration: duration, nominalFrameRate: nominalFrameRate),
            duration: duration,
            nominalFrameRate: nominalFrameRate)
    }
}
