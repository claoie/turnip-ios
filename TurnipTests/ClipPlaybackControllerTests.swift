import AVFoundation
import XCTest
@testable import Turnip

/// The tap state machine, the resume-past-the-window re-seek, and the accessibility fork at
/// the end of the loop. All three are decided from the playhead and the system autoplay
/// setting, so the tests drive a player whose playhead they set and a stubbed setting.
@MainActor
final class ClipPlaybackControllerTests: XCTestCase {
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func makeItem(
        id: UUID = UUID(), startTime: TimeInterval = 2, endTime: TimeInterval = 5
    ) -> ClipListItem {
        ClipListItem(
            id: id, window: TrickWindow(startTime: startTime, endTime: endTime),
            cropRect: fullFrame)
    }

    /// Callers `defer { controller.stop() }`: playing arms an end-boundary observer on the
    /// player, and `stop()` is how the list releases it when a card goes away.
    private func makeController(
        autoplayEnabled: Bool = true
    ) -> (ClipPlaybackController, RecordingPlayer) {
        let player = RecordingPlayer()
        let controller = ClipPlaybackController(
            // AVAsset is abstract and these tests never decode; the URL resolves to nothing.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            makePlayer: { player },
            isVideoAutoplayEnabled: { autoplayEnabled })
        return (controller, player)
    }

    // MARK: - The three-way tap

    func testTappingAnInactiveClipPlaysItFromItsWindowStart() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem()

        controller.toggle(item)

        XCTAssertEqual(controller.activeItemID, item.id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.seekTimes, [2])
        XCTAssertEqual(player.playCount, 1)
    }

    func testTappingThePlayingClipPausesItAndLeavesItActive() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem()

        controller.toggle(item)
        controller.toggle(item)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.activeItemID, item.id)
        XCTAssertEqual(player.pauseCount, 1)
        // Only the opening play's seek: pausing leaves the playhead where it is.
        XCTAssertEqual(player.seekTimes, [2])
    }

    func testTappingTheActivePausedClipResumesWhereItStopped() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem()

        controller.toggle(item)
        player.currentTimeSeconds = 3.5
        controller.toggle(item)
        controller.toggle(item)

        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.playCount, 2)
        // Resuming, not replaying: `play()` in this branch would seek back to 2 a second time.
        XCTAssertEqual(player.seekTimes, [2])
    }

    func testTappingADifferentClipStartsItFromItsOwnWindow() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let first = makeItem(startTime: 2, endTime: 5)
        let second = makeItem(startTime: 8, endTime: 11)

        controller.toggle(first)
        controller.toggle(second)

        XCTAssertEqual(controller.activeItemID, second.id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.seekTimes, [2, 8])
    }

    // MARK: - Resuming from outside the window

    /// Trimming a clip's end shorter while it is paused leaves the shared player's playhead
    /// past the new `endTime`. Resuming has to re-enter the window, or the tile plays material
    /// outside its own clip and the boundary observer — armed at a time already behind the
    /// playhead — never fires to loop it back.
    func testResumingAfterTheWindowEndMovedBehindThePlayheadSeeksToTheStart() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem(startTime: 2, endTime: 5)

        controller.toggle(item)
        player.currentTimeSeconds = 4
        controller.toggle(item)
        controller.toggle(makeItem(id: item.id, startTime: 2, endTime: 3.5))

        XCTAssertEqual(player.seekTimes, [2, 2])
        XCTAssertTrue(controller.isPlaying)
    }

    /// The comparison is `>=`: a playhead resting exactly on the boundary is already out.
    func testResumingWithThePlayheadExactlyAtTheWindowEndSeeksToTheStart() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem(startTime: 2, endTime: 5)

        controller.toggle(item)
        controller.toggle(item)
        player.currentTimeSeconds = 5
        controller.toggle(item)

        XCTAssertEqual(player.seekTimes, [2, 2])
    }

    func testResumingWithThePlayheadInsideTheWindowDoesNotSeek() {
        let (controller, player) = makeController()
        defer { controller.stop() }
        let item = makeItem(startTime: 2, endTime: 5)

        controller.toggle(item)
        controller.toggle(item)
        player.currentTimeSeconds = 4.999
        controller.toggle(item)

        XCTAssertEqual(player.seekTimes, [2])
    }

    // MARK: - The end-of-window loop

    func testTheLoopRestartsTheWindowWhenAutoplayIsOn() {
        let (controller, player) = makeController(autoplayEnabled: true)
        defer { controller.stop() }

        controller.toggle(makeItem(startTime: 2, endTime: 5))
        player.currentTimeSeconds = 5
        controller.loopBack()

        XCTAssertEqual(player.seekTimes, [2, 2])
        XCTAssertEqual(player.pauseCount, 0)
        XCTAssertTrue(controller.isPlaying)
    }

    /// docs/ACCESSIBILITY.md's Clip List checklist: with the system video-autoplay setting off,
    /// reaching the window's end stops rather than starting another pass.
    func testTheLoopPausesAtTheWindowEndWhenAutoplayIsOff() {
        let (controller, player) = makeController(autoplayEnabled: false)
        defer { controller.stop() }

        controller.toggle(makeItem(startTime: 2, endTime: 5))
        player.currentTimeSeconds = 5
        controller.loopBack()

        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertEqual(player.seekTimes, [2])
        XCTAssertFalse(controller.isPlaying)
    }
}

/// A player the tests drive directly. A real `AVPlayer` holding no loadable item reports an
/// invalid `currentTime()`, which is the one value every branch under test reads, and its
/// `seek` would be a no-op against nothing — so both are stubbed and recorded instead.
private final class RecordingPlayer: AVPlayer, @unchecked Sendable {
    var currentTimeSeconds: TimeInterval = 0
    private(set) var seekTimes: [TimeInterval] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0

    override func currentTime() -> CMTime {
        CMTime(seconds: currentTimeSeconds, preferredTimescale: 600)
    }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seekTimes.append(time.seconds)
        currentTimeSeconds = time.seconds
    }

    override func play() {
        playCount += 1
    }

    override func pause() {
        pauseCount += 1
    }

    /// Swapping in an item built from the tests' placeholder asset would only fail to load
    /// asynchronously; nothing asserted here reads it.
    override func replaceCurrentItem(with item: AVPlayerItem?) {}
}
