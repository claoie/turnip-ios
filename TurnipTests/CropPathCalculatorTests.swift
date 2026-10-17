import CoreGraphics
import XCTest
@testable import Turnip

final class CropPathCalculatorTests: XCTestCase {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let calculator = CropPathCalculator()

    /// A full 17-keypoint frame at `time`: the given points take the leading COCO names and every
    /// name left over sits at the origin below the confidence threshold, so a path that stopped
    /// filtering by confidence would be dragged to (0, 0).
    private func frame(at time: TimeInterval, _ points: [(x: Float, y: Float)]) -> PoseFrameResult {
        let located = zip(PoseKeypoint.names, points).map { name, point in
            PoseKeypoint(name: name, y: point.y, x: point.x, confidence: 0.9)
        }
        let unlocated = PoseKeypoint.names.dropFirst(points.count).map { name in
            PoseKeypoint(name: name, y: 0, x: 0, confidence: 0.05)
        }
        return PoseFrameResult(frameIndex: Int((time * 30).rounded()), timestamp: time,
                               keypoints: located + unlocated)
    }

    /// An athlete standing upright between y 0.3 and 0.7, `width` wide, left edge at `x`.
    private func athlete(at time: TimeInterval, x: Float, width: Float = 0.02) -> PoseFrameResult {
        frame(at: time, [(x: x, y: 0.3), (x: x + width, y: 0.7)])
    }

    private func centerX(_ rect: NormalizedRect) -> Float { (rect.minX + rect.maxX) / 2 }
    private func centerY(_ rect: NormalizedRect) -> Float { (rect.minY + rect.maxY) / 2 }

    func testNoLocatedKeypointYieldsNoPath() {
        let frames = (0..<5).map { frame(at: Double($0) * 0.1, []) }

        XCTAssertNil(calculator.cropPath(for: frames, renderedPixelSize: landscape))
    }

    func testUnknownFrameSizeYieldsNoPath() {
        let frames = (0..<5).map { athlete(at: Double($0) * 0.1, x: 0.5) }

        XCTAssertNil(calculator.cropPath(for: frames, renderedPixelSize: .zero))
    }

    /// Keypoint jitter on an athlete standing still is the case a moving crop turns into camera
    /// shake, so it gets a still crop centered on everything the window located.
    func testAJitteringStillAthleteGetsAStillCrop() throws {
        let frames = (0..<20).map { index in
            athlete(at: Double(index) * 0.1, x: index.isMultiple(of: 2) ? 0.505 : 0.495)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertTrue(path.isStatic)
        XCTAssertEqual(centerX(path.keyframes[0].rect), 0.51, accuracy: 0.00001)
        XCTAssertEqual(centerY(path.keyframes[0].rect), 0.5, accuracy: 0.00001)
    }

    func testTheCropFollowsAnAthleteCrossingTheFrame() throws {
        let frames = (0..<40).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.015 * Float($0)) }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertFalse(path.isStatic)
        XCTAssertEqual(path.keyframes.count, 40)
        let centers = path.keyframes.map { centerX($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }, "\(centers)")
        // Steady motion is followed exactly at both ends, not dragged toward the middle.
        XCTAssertEqual(centers[0], 0.21, accuracy: 0.0001)
        XCTAssertEqual(centers[39], 0.795, accuracy: 0.0001)
    }

    /// The clip never zooms: every keyframe is the rect the static crop would draw around the
    /// largest single sample, at the target ratio in pixels.
    func testEveryKeyframeHoldsTheLargestSamplesRect() throws {
        let frames = (0..<30).map { index -> PoseFrameResult in
            let height: Float = index < 15 ? 0.2 : 0.5
            let x = 0.2 + 0.02 * Float(index)
            return frame(at: Double(index) * 0.1, [(x: x, y: 0.4), (x: x + 0.02, y: 0.4 + height)])
        }
        let tallest = try XCTUnwrap(CropRectCalculator().cropRect(
            for: [frames[29]], renderedPixelSize: landscape))

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for keyframe in path.keyframes {
            XCTAssertEqual(keyframe.rect.width, tallest.width, accuracy: 0.00001)
            XCTAssertEqual(keyframe.rect.height, tallest.height, accuracy: 0.00001)
            let pixelRatio = keyframe.rect.width * Float(landscape.width)
                / (keyframe.rect.height * Float(landscape.height))
            XCTAssertEqual(pixelRatio, 9.0 / 16.0, accuracy: 0.0001)
        }
    }

    /// Alternating keypoint noise four times the size of each step forward would make a crop that
    /// chased the raw centers step back on every other frame.
    func testJitterOnAMovingAthleteDoesNotShakeTheCrop() throws {
        let frames = (0..<40).map { index in
            let noise: Float = index.isMultiple(of: 2) ? 0.01 : -0.01
            return athlete(at: Double(index) * 0.1, x: 0.3 + 0.005 * Float(index) + noise)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertFalse(path.isStatic)
        let centers = path.keyframes.map { centerX($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 <= $1 }, "\(centers)")
    }

    /// Smoothing lets the crop lag a sudden move; the containment step is what keeps the athlete
    /// in the shot anyway.
    func testEveryLocatedJointStaysInsideItsKeyframe() throws {
        let frames = (0..<30).map { index in
            athlete(at: Double(index) * 0.1, x: index < 15 ? 0.2 : 0.7, width: 0.05)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for (frame, keyframe) in zip(frames, path.keyframes) {
            for point in CropRectCalculator.locatedPoints(in: [frame]) {
                XCTAssertGreaterThanOrEqual(Float(point.x), keyframe.rect.minX - 0.00001, "t=\(keyframe.time)")
                XCTAssertLessThanOrEqual(Float(point.x), keyframe.rect.maxX + 0.00001, "t=\(keyframe.time)")
            }
        }
    }

    func testAFrameWithNoLocatedJointIsPlacedByItsNeighbours() throws {
        let frames = (0..<30).map { index in
            (10...12).contains(index)
                ? frame(at: Double(index) * 0.1, [])
                : athlete(at: Double(index) * 0.1, x: 0.2 + 0.015 * Float(index))
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertEqual(path.keyframes.count, 30)
        let athleteCenterAtFrame11: Float = 0.2 + 0.015 * 11 + 0.01
        XCTAssertEqual(centerX(path.keyframes[11].rect), athleteCenterAtFrame11, accuracy: 0.0001)
    }

    func testTheCropNeverLeavesTheFrame() throws {
        let frames = (0..<30).map { athlete(at: Double($0) * 0.1, x: 0.002 * Float($0)) }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for keyframe in path.keyframes {
            XCTAssertGreaterThanOrEqual(keyframe.rect.minX, 0)
            XCTAssertLessThanOrEqual(keyframe.rect.maxX, 1)
            XCTAssertGreaterThanOrEqual(keyframe.rect.minY, 0)
            XCTAssertLessThanOrEqual(keyframe.rect.maxY, 1)
        }
        XCTAssertEqual(path.keyframes[0].rect.minX, 0, accuracy: 0.00001)
    }

    /// Smoothing is measured in seconds, so the analysis granularity setting changes how often
    /// the athlete is sampled and not how the crop moves.
    func testTheSamplingRateDoesNotChangeThePath() throws {
        func frames(every interval: TimeInterval) -> [PoseFrameResult] {
            stride(from: 0.0, through: 4.0, by: interval).map { time in
                athlete(at: time, x: 0.3 + 0.2 * Float(sin(time * 1.5)))
            }
        }

        let coarse = try XCTUnwrap(calculator.cropPath(for: frames(every: 0.1), renderedPixelSize: landscape))
        let fine = try XCTUnwrap(calculator.cropPath(for: frames(every: 0.05), renderedPixelSize: landscape))

        for keyframe in coarse.keyframes {
            XCTAssertEqual(centerX(fine.rect(at: keyframe.time)), centerX(keyframe.rect), accuracy: 0.003,
                           "t=\(keyframe.time)")
        }
    }

    func testFramesOutOfTimeOrderGiveTheSamePath() throws {
        let frames = (0..<20).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.02 * Float($0)) }

        let sorted = calculator.cropPath(for: frames, renderedPixelSize: landscape)
        let shuffled = calculator.cropPath(for: frames.reversed(), renderedPixelSize: landscape)

        XCTAssertEqual(shuffled, sorted)
    }

    func testRectAtInterpolatesBetweenKeyframesAndHoldsOutsideThem() {
        let left = NormalizedRect(minX: 0, maxX: 0.2, minY: 0, maxY: 0.5)
        let right = NormalizedRect(minX: 0.4, maxX: 0.6, minY: 0.5, maxY: 1)
        let path = CropPath(keyframes: [CropKeyframe(time: 1, rect: left), CropKeyframe(time: 2, rect: right)])

        XCTAssertEqual(path.rect(at: 0), left)
        XCTAssertEqual(path.rect(at: 3), right)
        let halfway = path.rect(at: 1.5)
        XCTAssertEqual(halfway.minX, 0.2, accuracy: 0.00001)
        XCTAssertEqual(halfway.maxX, 0.4, accuracy: 0.00001)
        XCTAssertEqual(halfway.minY, 0.25, accuracy: 0.00001)
        XCTAssertEqual(halfway.maxY, 0.75, accuracy: 0.00001)
    }
}
