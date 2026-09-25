import AVFoundation
import Foundation
import XCTest
@testable import Turnip

/// A stand-in for a tile's real loop: records the lifecycle calls it received and the
/// window it was built over, so a test can assert both what ran and which range would
/// have played.
private final class FakeLoop: ClipLooping {
    let player = AVQueuePlayer()
    let window: TrickWindow
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0

    init(window: TrickWindow) {
        self.window = window
    }

    func play() {
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

/// Every loop `ClipCardPlayback` asked for, in order, plus the autoplay setting it reads.
/// A class so a test can flip `isAutoplayEnabled` after construction — the system setting
/// can change while a tile is mounted.
private final class LoopRecorder {
    var isAutoplayEnabled = true
    var loops: [FakeLoop] = []
}

@MainActor
final class ClipCardPlaybackTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    /// The same clip after an editor commit shortened its end. Distinct from `window`, so
    /// a rebuild that reuses the pre-edit loop is visible rather than indistinguishable.
    private let editedWindow = TrickWindow(startTime: 2, endTime: 3.5)

    /// `AVAsset` is abstract and throws at runtime, so this uses the concrete
    /// `AVURLAsset`. The URL resolves to nothing and never needs to — no test here builds
    /// a real loop over it.
    private func makePlayback(_ recorder: LoopRecorder) -> ClipCardPlayback {
        ClipCardPlayback(
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            isAutoplayEnabled: { recorder.isAutoplayEnabled },
            makeLoop: { _, window in
                let loop = FakeLoop(window: window)
                recorder.loops.append(loop)
                return loop
            })
    }

    // MARK: - The autoplay-off fallback

    func testAutoplayDisabledBuildsNoLoopAtAll() {
        let recorder = LoopRecorder()
        recorder.isAutoplayEnabled = false
        let playback = makePlayback(recorder)

        playback.start(window: window, isSuspended: false)

        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    func testAutoplayDisabledWhileSuspendedKeepsTheTilePausedOnResume() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)
        playback.setSuspended(true)

        recorder.isAutoplayEnabled = false
        playback.setSuspended(false)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 1)
        XCTAssertEqual(recorder.loops[0].pauseCount, 1)
    }

    // MARK: - Mounting and releasing

    func testStartBuildsALoopOverTheItemsWindowAndPlaysIt() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(window: window, isSuspended: false)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].window, window)
        XCTAssertEqual(recorder.loops[0].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[0])
    }

    func testStartWhileSuspendedBuildsNoLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(window: window, isSuspended: true)

        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    func testRepeatedStartResumesTheSameLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(window: window, isSuspended: false)
        playback.start(window: window, isSuspended: false)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 2)
    }

    /// The window can also arrive through `start` — `.task(id: item)` re-fires on an
    /// editor commit — with the pre-edit loop still mounted and nothing having torn it
    /// down. Asserts the *new* loop's range, so reusing the stale one fails.
    func testStartWithAChangedWindowRebuildsOverTheNewRange() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)

        playback.start(window: editedWindow, isSuspended: false)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertEqual(recorder.loops[1].window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    func testTeardownReleasesTheLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)

        playback.teardown()

        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertNil(playback.loop)
    }

    func testStartAfterTeardownBuildsAFreshLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)
        playback.teardown()

        playback.start(window: window, isSuspended: false)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    // MARK: - Suspension while the editor covers the grid

    func testSuspendingPausesWithoutReleasingTheLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)

        playback.setSuspended(true)

        XCTAssertEqual(recorder.loops[0].pauseCount, 1)
        XCTAssertEqual(recorder.loops[0].stopCount, 0)
        XCTAssertNotNil(playback.loop)
    }

    func testResumingReusesTheMountedLoop() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)
        playback.setSuspended(true)

        playback.setSuspended(false)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 2)
    }

    // MARK: - An editor commit that moves the window

    func testWindowChangeRebuildsTheLoopOverTheNewRange() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)

        playback.windowChanged(to: editedWindow)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertEqual(recorder.loops[1].window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    func testWindowChangeWhileSuspendedRebuildsOnResumeNotOnThePreEditRange() {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(window: window, isSuspended: false)
        playback.setSuspended(true)

        playback.windowChanged(to: editedWindow)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertNil(playback.loop)

        // No window argument: the rebuild can only come from what `windowChanged` stored,
        // so the assertion below can't pass on a value this test just handed in.
        playback.setSuspended(false)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[1].window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
    }
}
