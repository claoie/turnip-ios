import XCTest

/// Screenshot automation for UI-change PRs (CONTRIBUTING.md asks for screenshots
/// on UI changes): launches the app into scripted states via launch arguments
/// (see `ScreenshotHarness.swift`) and captures XCUITest screenshots. Each test
/// prints its PNG as base64 to stdout (TURNIP_SCREENSHOT:<name>:<base64>); the CI
/// screenshots job greps the log and uploads the PNGs as the pr-screenshots
/// artifact, and the screenshots-comment workflow posts them on the PR — so
/// nobody needs a local simulator to produce PR screenshots.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Home's Photos-denied empty state: the only Home state scriptable without the
    /// Photos library (the grid needs real PHAssets, which have no public
    /// initializer, and the real HomeView would raise the system permission prompt).
    func testHomeAccessDenied() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHome"]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Turnip needs access to your videos"]
                .waitForExistence(timeout: 15))
        addScreenshot(named: "home-access-denied")
    }

    /// Clip list triage: three detected windows, one trashed, thumbnails as
    /// placeholder tiles (the /dev/null asset decodes nothing; the loader falls
    /// back to the placeholder — the test waits for the placeholder's
    /// accessibility element, so it guards the fallback and not just the
    /// navigation bar appearing).
    func testClipListTriage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipList"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let placeholder = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Thumbnail placeholder'"))
            .firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-triage")
    }

    /// Clip list over real media: the `/dev/null` asset in `testClipListTriage` never
    /// loads a duration, so its tiles' read-only range timeline stays hidden behind its
    /// `if let duration` guard — this proves the timeline actually renders once the
    /// asset loads for real.
    func testClipListMedia() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let rangeTimeline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Clip from'"))
            .firstMatch
        XCTAssertTrue(rangeTimeline.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-media")
    }

    /// Trashing the original tile flips its icon button's accessibility label rather
    /// than removing it, and the screen carries no leftover select-all affordance —
    /// the triage screen's toolbar now has only the back chevron, and "Done"
    /// replaced "Export N clips". The original tile is always the first of the
    /// grid's "Trash clip" buttons, since `ClipListViewModel` prepends it to `items`.
    func testTrashButtonTogglesToRestoreOnTheOriginalTile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let trashButtons = app.buttons.matching(NSPredicate(format: "label == 'Trash clip'"))
        let originalTrashButton = trashButtons.element(boundBy: 0)
        XCTAssertTrue(originalTrashButton.waitForExistence(timeout: 15))
        originalTrashButton.tap()

        XCTAssertTrue(app.buttons["Restore clip"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.buttons["Deselect All"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    /// A derived clip's trash button removes its tile from the grid immediately,
    /// unlike the original tile's reversible toggle above — no "Restore clip" label
    /// ever appears for it.
    func testTrashButtonRemovesADerivedClipImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let openClipTiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Open clip'"))
        XCTAssertEqual(openClipTiles.count, 2) // the fixture's two derived clips

        let trashButtons = app.buttons.matching(NSPredicate(format: "label == 'Trash clip'"))
        XCTAssertEqual(trashButtons.count, 3) // original tile + two derived clips
        let derivedTrashButton = trashButtons.element(boundBy: 1)
        XCTAssertTrue(derivedTrashButton.waitForExistence(timeout: 15))
        derivedTrashButton.tap()

        // Waits for the tile to actually leave the grid rather than asserting right
        // after the tap: a same-instant assertion on the trash-button count alone
        // can't tell removal apart from a relabel to "Restore clip", since both drop
        // that count by one.
        wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: openClipTiles)], timeout: 5)
        XCTAssertFalse(app.buttons["Restore clip"].exists)
    }

    /// Tapping a tile opens the full `ClipEditorView` directly — the tile itself is
    /// the single entry point into detail/editing, not a separate expand icon and not
    /// an intermediate full-screen viewer.
    func testClipListTapOpensEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Open clip'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Edit clip"].waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-expand-to-editor")
    }

    /// Clip editor over a generated sample movie: the preview with the live crop
    /// rect, the trim slider, and the keep toggle. The trim range's accessibility
    /// label ("Trim range 2.0s to 5.0s") only appears once the movie's duration
    /// loads, so it also proves the editor reached its loaded state.
    ///
    /// The wait is longer than this file's usual 15s: unlike every other wait
    /// here, which is on SwiftUI state already computed in memory, this element
    /// waits on `ScreenshotClipEditorHarness`'s `AVAssetWriter` encode plus the
    /// player's async duration load — real wall-clock work whose duration swings
    /// with host CPU contention on a shared CI runner.
    func testClipEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipEditor"]
        app.launch()
        let trimRange = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim range 2.0s to 5.0s'"))
            .firstMatch
        XCTAssertTrue(trimRange.waitForExistence(timeout: 45))
        addScreenshot(named: "clip-editor")
    }

    /// Processing mid-run: the stub runner reports "Analyzing frame 400 of 1200"
    /// and holds the run open (the test runner kills the app before the hold
    /// expires). No inference, no model, no video file.
    func testProcessingProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessing"]
        app.launch()
        let progress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Analysis progress'"))
            .firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        addScreenshot(named: "processing-progress")
    }

    /// Processing's resting state: the picked video full-screen with the custom scrub
    /// bar and the "Start analysis" button — no native `VideoPlayer` chrome and no
    /// caption text.
    func testProcessingIdle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        XCTAssertTrue(app.buttons["Start analysis"].waitForExistence(timeout: 15))
        addScreenshot(named: "processing-idle")
    }

    /// Pose diagnostic before a run: the video length and the "Run diagnostic"
    /// button. No inference runs until the button is tapped, so the initial state
    /// needs neither the model nor a real video file.
    func testPoseDiagnosticInitial() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotPoseDiagnostic"]
        app.launch()
        XCTAssertTrue(app.buttons["Run diagnostic"].waitForExistence(timeout: 15))
        addScreenshot(named: "pose-diagnostic")
    }

    private func addScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Print base64 PNG to stdout for CI extraction (env vars don't propagate
        // to the test runner, and xcresult parsing is fragile).
        // The workflow greps for TURNIP_SCREENSHOT:<name>:<base64>.
        let b64 = screenshot.pngRepresentation.base64EncodedString()
        print("TURNIP_SCREENSHOT:\(name):\(b64)")
    }
}
