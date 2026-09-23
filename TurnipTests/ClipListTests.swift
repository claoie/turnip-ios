import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import Turnip

final class ClipListTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func makeItem(isTrashed: Bool = false) -> ClipListItem {
        ClipListItem(window: window, cropRect: fullFrame, isTrashed: isTrashed)
    }

    /// `AVAsset` is abstract and throws at runtime, so the view-model tests use the
    /// concrete `AVURLAsset` subclass. The URL resolves to nothing — these tests never
    /// decode, they only exercise the trash and save logic.
    private func dummyAsset() -> AVURLAsset {
        AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
    }

    /// Builds a view model whose `items[0]` is always the injected original item —
    /// the invariant `ClipListViewModel.init` enforces — followed by `items`.
    @MainActor
    private func makeViewModel(
        items: [ClipListItem],
        asset: AVURLAsset? = nil,
        assetIdentifier: String = "asset-1",
        duration: TimeInterval = 30,
        exportClip: @escaping ExportOneClip = { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") },
        saveToPhotos: @escaping SaveOneClipToPhotos = { _ in },
        deleteOriginalAsset: @escaping DeleteOriginalAsset = { _ in }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items,
            asset: asset ?? dummyAsset(),
            assetIdentifier: assetIdentifier,
            duration: duration,
            exportClip: exportClip,
            saveToPhotos: saveToPhotos,
            deleteOriginalAsset: deleteOriginalAsset,
            makeDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
            })
    }

    /// A 90°-rotated track's preferredTransform: landscape-encoded portrait video.
    /// Encoded (0,0) is the displayed top-right, so it discriminates transforms that mix up
    /// encoded and displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    // MARK: - ClipListItem

    func testNewItemsStartUntrashed() {
        XCTAssertFalse(makeItem().isTrashed)
    }

    func testDurationLabelShowsOneDecimalSecond() {
        XCTAssertEqual(makeItem().durationLabel, "3.0s")
    }

    func testDurationLabelRoundsToOneDecimal() {
        let item = ClipListItem(
            window: TrickWindow(startTime: 1, endTime: 3.35), cropRect: fullFrame)
        XCTAssertEqual(item.durationLabel, "2.4s")
    }

    // MARK: - ClipListViewModel: the original item

    @MainActor
    func testOriginalItemIsAlwaysFirst() {
        let viewModel = makeViewModel(items: [makeItem(), makeItem()], duration: 12)

        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertTrue(viewModel.items[0].isOriginal)
        XCTAssertFalse(viewModel.items[1].isOriginal)
        XCTAssertFalse(viewModel.items[2].isOriginal)
    }

    @MainActor
    func testOriginalItemSpansTheFullDuration() {
        let viewModel = makeViewModel(items: [], duration: 12)

        XCTAssertEqual(viewModel.items[0].window, TrickWindow(startTime: 0, endTime: 12))
        XCTAssertEqual(viewModel.items[0].cropRect, fullFrame)
        XCTAssertFalse(viewModel.items[0].isTrashed)
    }

    @MainActor
    func testDeleteNeverRemovesTheOriginalItem() {
        let viewModel = makeViewModel(items: [])
        let originalId = viewModel.items[0].id

        viewModel.delete(originalId)

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items[0].isOriginal)
    }

    // MARK: - ClipListViewModel: trash toggle

    @MainActor
    func testToggleTrashFlipsOnlyTheTappedCard() {
        let first = makeItem(), second = makeItem()
        let viewModel = makeViewModel(items: [first, second])

        viewModel.toggleTrash(first)

        XCTAssertTrue(viewModel.items[1].isTrashed)
        XCTAssertFalse(viewModel.items[2].isTrashed)

        viewModel.toggleTrash(first)
        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testToggleTrashIgnoresUnknownItems() {
        let viewModel = makeViewModel(items: [makeItem()])

        viewModel.toggleTrash(makeItem())

        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testToggleTrashWorksOnTheOriginalItem() {
        let viewModel = makeViewModel(items: [])
        let original = viewModel.items[0]

        viewModel.toggleTrash(original)

        XCTAssertTrue(viewModel.items[0].isTrashed)
    }

    @MainActor
    func testBindingWritesThroughToTheListEntry() {
        let target = makeItem()
        let viewModel = makeViewModel(items: [makeItem(), target])

        guard let binding = viewModel.binding(for: target.id) else {
            XCTFail("expected a binding for an item that is in the list")
            return
        }
        binding.wrappedValue.isTrashed = true

        // The binding writes through to the list entry with the same id — the editor
        // destination edits the clip the card tapped.
        XCTAssertTrue(viewModel.items[2].isTrashed)
        XCTAssertFalse(viewModel.items[1].isTrashed)
    }

    @MainActor
    func testBindingIsNilForAnItemThatIsNotInTheList() {
        let viewModel = makeViewModel(items: [makeItem()])

        XCTAssertNil(viewModel.binding(for: makeItem().id))
    }

    // MARK: - Editor destination

    @MainActor
    func testApplyEditorResultReplacesTheMatchingItem() {
        let target = makeItem()
        let other = makeItem()
        let viewModel = makeViewModel(items: [other, target])

        let result = ClipEditorResult(
            window: TrickWindow(startTime: 1, endTime: 4),
            cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9),
            cropAdjustment: CropAdjustment(scale: 1.5, rotationRadians: 0, offset: .zero))
        viewModel.applyEditorResult(result, to: target.id)

        // The editor's commit lands on the tapped item — window, crop rect, and crop
        // adjustment — and leaves the rest of the list (and the item's own trash
        // decision, which the editor doesn't own) alone.
        let updated = viewModel.items[2]
        XCTAssertEqual(updated.id, target.id)
        XCTAssertEqual(updated.window, result.window)
        XCTAssertEqual(updated.cropRect, result.cropRect)
        XCTAssertEqual(updated.cropAdjustment, result.cropAdjustment)
        XCTAssertEqual(updated.isTrashed, target.isTrashed)
        XCTAssertEqual(viewModel.items[1], other)
    }

    @MainActor
    func testApplyEditorResultIgnoresUnknownIds() {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])

        viewModel.applyEditorResult(
            ClipEditorResult(
                window: TrickWindow(startTime: 1, endTime: 4),
                cropRect: fullFrame,
                cropAdjustment: .identity),
            to: makeItem().id)

        XCTAssertEqual(viewModel.items[1], item)
    }

    /// Regression for the stale-thumbnail bug: `thumbnail(for:)` decodes through the real
    /// `ClipThumbnailLoader` against a real one-frame video. The edit changes only
    /// `cropRect` (same window, same midpoint, so the seek target is identical both
    /// times) to a half-width crop — the decoded image's width is the discriminator: a
    /// stale cache hit would keep returning the full-width image, so this fails before
    /// the fix and passes only once the second call genuinely re-decodes.
    @MainActor
    func testApplyEditorResultInvalidatesTheCachedThumbnail() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 1, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let item = ClipListItem(window: TrickWindow(startTime: 0, endTime: 1.0 / 30), cropRect: fullFrame)
        let viewModel = makeViewModel(items: [item], asset: asset, duration: 1.0 / 30)
        let target = viewModel.items[1]

        let beforeImage = await viewModel.thumbnail(for: target)
        let before = try XCTUnwrap(beforeImage)
        XCTAssertEqual(before.width, 64)

        let halfWidth = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let result = ClipEditorResult(window: item.window, cropRect: halfWidth, cropAdjustment: .identity)
        viewModel.applyEditorResult(result, to: target.id)
        let updated = viewModel.items[1]
        XCTAssertEqual(updated.cropRect, halfWidth)

        let afterImage = await viewModel.thumbnail(for: updated)
        let after = try XCTUnwrap(afterImage)
        XCTAssertEqual(after.width, 32)
    }

    @MainActor
    func testDeleteRemovesTheMatchingItem() {
        let target = makeItem()
        let other = makeItem()
        let viewModel = makeViewModel(items: [other, target])

        viewModel.delete(target.id)

        XCTAssertEqual(viewModel.items[1], other)
        XCTAssertEqual(viewModel.items.count, 2)
    }

    @MainActor
    func testDeleteIgnoresUnknownIds() {
        let item = makeItem()
        let viewModel = makeViewModel(items: [item])

        viewModel.delete(makeItem().id)

        XCTAssertEqual(viewModel.items[1], item)
    }

    @MainActor
    func testEditorSourceCarriesTheItemAndAsset() {
        let asset = dummyAsset()
        let item = makeItem()
        let viewModel = makeViewModel(items: [item], asset: asset)

        let source = viewModel.editorSource(for: item)

        XCTAssertEqual(source.window, item.window)
        XCTAssertEqual(source.cropRect, item.cropRect)
        XCTAssertEqual(source.cropAdjustment, item.cropAdjustment)
        XCTAssertTrue(source.asset === asset)
    }

    // MARK: - save()

    @MainActor
    func testSaveExportsAndSavesEveryNonTrashedDerivedClip() async {
        actor Recorder {
            var exportedWindows: [TrickWindow] = []
            var savedURLs: [URL] = []
            func recordExport(_ window: TrickWindow) { exportedWindows.append(window) }
            func recordSave(_ url: URL) { savedURLs.append(url) }
        }
        let recorder = Recorder()
        let kept = makeItem()
        let trashed = makeItem(isTrashed: true)
        let viewModel = makeViewModel(
            items: [kept, trashed],
            exportClip: { spec, _, directory, _ in
                await recorder.recordExport(spec.window)
                return directory.appendingPathComponent("\(UUID().uuidString).mp4")
            },
            saveToPhotos: { url in await recorder.recordSave(url) })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let windows = await recorder.exportedWindows
        XCTAssertEqual(windows, [kept.window])
        let saved = await recorder.savedURLs
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(viewModel.saveFailureMessage)
    }

    @MainActor
    func testSaveNeverExportsTheOriginalItem() async {
        actor Recorder {
            var exportCount = 0
            func increment() { exportCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [],
            exportClip: { _, _, directory, _ in
                await recorder.increment()
                return directory.appendingPathComponent("clip.mp4")
            })

        _ = await viewModel.save()

        let count = await recorder.exportCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testSaveDeletesTheOriginalWhenItIsTrashedAndEverythingSucceeded() async {
        actor Recorder {
            var deletedIdentifiers: [String] = []
            func record(_ identifier: String) { deletedIdentifiers.append(identifier) }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            assetIdentifier: "original-123",
            deleteOriginalAsset: { identifier in await recorder.record(identifier) })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let deleted = await recorder.deletedIdentifiers
        XCTAssertEqual(deleted, ["original-123"])
    }

    @MainActor
    func testSaveLeavesTheOriginalAloneWhenItIsNotTrashed() async {
        actor Recorder {
            var deleteCount = 0
            func increment() { deleteCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            deleteOriginalAsset: { _ in await recorder.increment() })

        let result = await viewModel.save()

        XCTAssertTrue(result)
        let count = await recorder.deleteCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testSaveDoesNotDeleteTheOriginalWhenAClipFails() async {
        struct Boom: Error {}
        actor Recorder {
            var deleteCount = 0
            func increment() { deleteCount += 1 }
        }
        let recorder = Recorder()
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, _, _ in throw Boom() },
            deleteOriginalAsset: { _ in await recorder.increment() })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        XCTAssertFalse(result)
        let count = await recorder.deleteCount
        // A failed clip must never cost the original its only remaining copy: the
        // original stays until every derived clip has confirmed it landed in Photos.
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(viewModel.saveFailureMessage)
    }

    @MainActor
    func testSaveReportsExportFailureReason() async {
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, _, _ in throw ClipSaveError.exportFailed(reason: "boom") })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(viewModel.saveFailureMessage, "Export failed — boom")
    }

    @MainActor
    func testSaveReportsPhotosSaveFailureReason() async {
        let viewModel = makeViewModel(
            items: [makeItem()],
            saveToPhotos: { _ in throw ClipSaveError.photosSaveFailed(reason: "denied") })

        let result = await viewModel.save()

        XCTAssertFalse(result)
        XCTAssertEqual(viewModel.saveFailureMessage, "Couldn't save to Photos — denied")
    }

    @MainActor
    func testSaveIgnoresAFailedOriginalDeletion() async {
        struct Boom: Error {}
        let viewModel = makeViewModel(
            items: [],
            deleteOriginalAsset: { _ in throw Boom() })
        viewModel.toggleTrash(viewModel.items[0])

        let result = await viewModel.save()

        // A declined system delete-confirmation or a revoked permission leaves the
        // original in place, which is the safe outcome — not a reportable failure.
        XCTAssertTrue(result)
        XCTAssertNil(viewModel.saveFailureMessage)
    }

    @MainActor
    func testSaveIgnoresReentrantCallsWhileAlreadySaving() async {
        actor Gate {
            private var continuation: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { continuation = $0 } }
            func open() { continuation?.resume(); continuation = nil }
        }
        let gate = Gate()
        let viewModel = makeViewModel(
            items: [makeItem()],
            exportClip: { _, _, directory, _ in
                await gate.wait()
                return directory.appendingPathComponent("clip.mp4")
            })

        async let first = viewModel.save()
        // Give the first call a moment to set `isSaving` before the second races it.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await viewModel.save()
        await gate.open()

        XCTAssertFalse(second)
        _ = await first
    }

    // MARK: - Add clip

    @MainActor
    func testAddClipAppendsAFullFrameClip() async throws {
        // The dummy asset resolves to nothing, so duration never loads and the new
        // clip falls back to the default 3-second window — clamped to the minimum
        // clip duration, though 3s never actually hits that floor.
        let viewModel = makeViewModel(items: [])

        await viewModel.addClip()

        XCTAssertEqual(viewModel.items.count, 2)
        let added = viewModel.items[1]
        XCTAssertEqual(added.window.startTime, 0)
        XCTAssertEqual(added.window.endTime, 3)
        XCTAssertEqual(added.cropRect, fullFrame)
        XCTAssertFalse(added.isTrashed)
    }

    @MainActor
    func testAddClipAppendsAfterExistingItems() async {
        let existing = makeItem()
        let viewModel = makeViewModel(items: [existing])

        await viewModel.addClip()

        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertEqual(viewModel.items[1], existing)
    }

    // MARK: - ClipThumbnailLoader.displayedCropRect

    func testDisplayedCropRectWithIdentityTransformIsUnchanged() {
        // Fractions chosen exactly representable in Float so the assertion is exact —
        // the point here is the space mapping, not float dust.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: crop,
            naturalSize: CGSize(width: 200, height: 100),
            preferredTransform: .identity)

        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    func testDisplayedCropRectMapsARotatedTrackIntoDisplayedSpace() {
        // Full frame must become the portrait displayed frame.
        let full = ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 1080, height: 1920))

        // The crop rect is normalized in display orientation, so the displayed left half
        // maps straight onto the displayed left half. The old buggy mapping —
        // denormalize in the encoded size, then map through preferredTransform —
        // landed it on the displayed top half instead: (0, 0, 1080, 960).
        let leftHalf = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: leftHalf,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectUsesTheDisplayedSizeForPartialRects() {
        // A partial rect discriminates the encoded-vs-displayed denormalization: with the
        // old (buggy) denormalize-in-encoded-size + map-through-transform, this
        // display-normalized rect lands at (0, 480, 1080, 960) instead of (270, 0, 540, 1920).
        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1),
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)

        XCTAssertEqual(rect, CGRect(x: 270, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectReturnsNilForDegenerateInputs() {
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: .zero,
            preferredTransform: .identity))

        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: empty,
            naturalSize: CGSize(width: 100, height: 100),
            preferredTransform: .identity))
    }

    // MARK: - ClipThumbnailLoader.displayedAspectRatio

    func testDisplayedAspectRatioWithIdentityTransformMatchesTheCropRect() {
        // Fractions chosen exactly representable in Float so the assertion is exact.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: crop,
                naturalSize: CGSize(width: 200, height: 100),
                preferredTransform: .identity),
            4.0) // 100 wide x 25 tall
    }

    func testDisplayedAspectRatioUsesTheDisplayedSizeOnARotatedTrack() {
        // Portrait phone video: the crop rect is normalized in display orientation, so a
        // (0.25..<0.75, 0..<1) rect is a 9:32 portrait crop of the 1080x1920 displayed
        // frame. The old buggy mapping read it as an 8:9 encoded-space crop and reported
        // 9:8 (1.125) — the placeholder reserved the wrong shape, off by 4x.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: crop,
                naturalSize: CGSize(width: 1920, height: 1080),
                preferredTransform: rotate90),
            9.0 / 32.0, // 540 wide x 1920 tall displayed
            accuracy: 1e-6)
    }

    func testDisplayedAspectRatioFallsBackForDegenerateInputs() {
        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)

        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: empty,
                naturalSize: CGSize(width: 100, height: 100),
                preferredTransform: .identity),
            9.0 / 16.0)
        XCTAssertEqual(
            ClipThumbnailLoader.displayedAspectRatio(
                cropRect: fullFrame,
                naturalSize: .zero,
                preferredTransform: .identity),
            9.0 / 16.0)
    }

    // MARK: - ClipThumbnailLoader.croppedThumbnail

    func testCroppedThumbnailExtractsTheDisplayedCropAtPixelScale() throws {
        // 4x2 test image; the crop is given in displayed space (8x4), so the loader must
        // scale it down to the image's pixels. Forgetting the scale would crop outside the
        // image and return nil instead of a 2x2 thumbnail.
        let image = try XCTUnwrap(Self.testImage(width: 4, height: 2))

        let cropped = try XCTUnwrap(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 4, y: 0, width: 4, height: 4),
            in: CGSize(width: 8, height: 4)))

        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 2)

        // The crop is the right half of the displayed frame. Reading a pixel proves the
        // *region* was extracted, not just the size: an implementation that dropped the
        // crop's minX/minY and always cropped from the origin would read the red left
        // half here instead of the green right half.
        let pixel = try XCTUnwrap(Self.pixel(atX: 0, y: 0, in: cropped))
        XCTAssertLessThan(pixel.red, 0.5)
        XCTAssertGreaterThan(pixel.green, 0.5)
    }

    func testCroppedThumbnailReturnsNilWhenNothingSurvivesTheClamp() throws {
        let image = try XCTUnwrap(Self.testImage(width: 4, height: 2))

        // Entirely outside the displayed frame.
        XCTAssertNil(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 100, y: 100, width: 10, height: 10),
            in: CGSize(width: 8, height: 4)))
        // Degenerate displayed size.
        XCTAssertNil(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 0, y: 0, width: 4, height: 4),
            in: .zero))
    }

    // MARK: - ClipThumbnailLoader.thumbnail

    func testThumbnailReturnsNilWhenTheAssetHasNoVideoTrack() async throws {
        let loader = ClipThumbnailLoader()

        // A real audio-only file: track loading succeeds but finds no video track, so
        // the nil comes from the loader's no-video-track guard — not from a decode
        // throw. The card falls back to its placeholder tile; a throw must never reach
        // the view.
        let audioURL = try Self.audioOnlyFileURL()
        // The helper writes the WAV into tmp on every run; clean it up so the test
        // leaves no scratch behind.
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let result = await loader.thumbnail(
            for: makeItem(), in: AVURLAsset(url: audioURL))

        XCTAssertNil(result)
    }

    // MARK: - Helpers

    /// A minimal but structurally valid WAV (44-byte header, zero samples): AVFoundation
    /// parses it as an audio asset, so video-track loading succeeds with no video track.
    private static func audioOnlyFileURL() throws -> URL {
        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append("RIFF"); appendLE(UInt32(36)); append("WAVE")
        append("fmt "); appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(44_100))
        appendLE(UInt32(88_200)) // byte rate
        appendLE(UInt16(2)) // block align
        appendLE(UInt16(16)) // bits per sample
        append("data"); appendLE(UInt32(0)) // zero samples
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try header.write(to: url)
        return url
    }

    /// Test image split into two distinguishable halves — left red, right green — so a
    /// crop test can prove *which* region was extracted, not just its size. Colors are
    /// built in the same device-RGB space the context uses, so the halves read back as
    /// pure primaries.
    private static func testImage(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let halfWidth = width / 2
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: halfWidth, y: 0, width: width - halfWidth, height: height))
        return context.makeImage()
    }

    /// The RGBA bytes of one pixel, read in data order (top row first). The vertical
    /// orientation doesn't matter for the left/right-half assertions below.
    /// A pixel's normalized RGB components (avoids a >2-member tuple return).
    private struct PixelRGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private static func pixel(atX x: Int, y: Int, in image: CGImage) -> PixelRGB? {
        guard image.bitsPerPixel == 32,
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 4 <= data.count else { return nil }
        return PixelRGB(
            red: CGFloat(data[offset]) / 255,
            green: CGFloat(data[offset + 1]) / 255,
            blue: CGFloat(data[offset + 2]) / 255
        )
    }
}
