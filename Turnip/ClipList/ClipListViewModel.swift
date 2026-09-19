import AVFoundation
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Backing store for `ClipListView` (`docs/UIUX.md` § "Clip List (triage)").
@MainActor
final class ClipListViewModel: ObservableObject {
    @Published private(set) var items: [ClipListItem]

    /// Decoded thumbnails by item id. Plain storage, not `@Published`: no view reads
    /// this dictionary — each card renders from its own `@State` thumbnail — so
    /// publishing it would re-evaluate every card's body on every completed decode.
    private var thumbnails: [UUID: CGImage] = [:]

    private let asset: AVAsset
    private let loader: ClipThumbnailLoader
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    /// The asset's duration in seconds, loaded once per asset and shared by every
    /// card's inline trim timeline. `nil` when the asset can't be read — the timeline
    /// then hides itself rather than guessing a scale.
    private var durationTask: Task<TimeInterval?, Never>?

    init(
        items: [ClipListItem],
        asset: AVAsset,
        loader: ClipThumbnailLoader = ClipThumbnailLoader()
    ) {
        self.items = items
        self.asset = asset
        self.loader = loader
    }

    /// The export action's input. Non-empty by default since every item starts kept
    /// (see `ClipListItem`).
    var keptItems: [ClipListItem] {
        items.filter(\.isKept)
    }

    /// "Export N clips", disabled until at least one clip is kept.
    var exportTitle: String {
        let count = keptItems.count
        return "Export \(count) clip\(count == 1 ? "" : "s")"
    }

    var canExport: Bool {
        !keptItems.isEmpty
    }

    /// The analyzed asset, shared with the editor and export-confirmation
    /// destinations so they preview and export from the same source the list's
    /// thumbnails were decoded from.
    var sourceAsset: AVAsset { asset }

    /// The export action's input as the confirmation screen takes it: one entry
    /// per kept clip, carrying the id, window, and crop rect it exports with.
    var exportConfirmationItems: [ExportConfirmationItem] {
        keptItems.map {
            ExportConfirmationItem(
                id: $0.id, window: $0.window, cropRect: $0.cropRect,
                cropAdjustment: $0.cropAdjustment)
        }
    }

    /// Builds the editor's input for one list item: its window, crop rect, and crop
    /// adjustment plus the analyzed asset. Keep/discard stays the list's own decision —
    /// the editor no longer surfaces or edits it.
    ///
    /// `poseFrames` is empty — the pipeline's sampled frames don't reach the
    /// list yet (the Home → Processing wiring threads them through when it
    /// lands), so the editor keeps the pipeline-computed crop rect instead of
    /// re-deriving it when a trim handle drags outward past the original
    /// window. Trimming and the live crop preview both work; only the
    /// re-derivation for newly included frames waits on the frames.
    func editorSource(for item: ClipListItem) -> ClipEditorSource {
        ClipEditorSource(
            window: item.window,
            cropRect: item.cropRect,
            cropAdjustment: item.cropAdjustment,
            asset: asset,
            poseFrames: [])
    }

    /// Applies the editor's commit to the item with the given id: the window, crop rect,
    /// and crop adjustment the user left the editor with replace the list entry's, so
    /// trim/crop edits commit on back-navigation (docs/UIUX.md § "Clip Detail / Editor").
    /// The item's `isKept` carries over unchanged — the editor doesn't own that decision.
    /// A no-op for unknown ids — the item may have been removed by a re-run of detection,
    /// or deleted from the editor, while it was open.
    func applyEditorResult(_ result: ClipEditorResult, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = ClipListItem(
            id: id,
            window: result.window,
            cropRect: result.cropRect,
            cropAdjustment: result.cropAdjustment,
            isKept: items[index].isKept)
    }

    /// Removes the item with the given id entirely — the editor's Delete action, distinct
    /// from discarding: a discarded clip still shows in the grid (excluded from export
    /// only), while a deleted clip is gone. A no-op for unknown ids.
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// The per-card keep/discard quick action. A no-op for unknown ids — the card that
    /// fired it may have been removed by a re-run of detection.
    func toggleKeep(_ item: ClipListItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isKept.toggle()
    }

    /// True when every clip is kept (and there is at least one). Drives the toolbar's
    /// "Select All" / "Deselect All" label.
    var allKept: Bool {
        !items.isEmpty && items.allSatisfy(\.isKept)
    }

    /// Marks every clip kept — the toolbar's "Select All" action.
    func selectAll() {
        for index in items.indices {
            items[index].isKept = true
        }
    }

    /// Clears every clip's keep flag — the toolbar's "Deselect All" action, shown when
    /// everything is already kept.
    func deselectAll() {
        for index in items.indices {
            items[index].isKept = false
        }
    }

    /// A write-through binding to one item, for a destination that edits a clip in place.
    /// Keyed by id on both ends rather than closing over an index: get and set resolve
    /// the item from the current list. `nil` when the id is no longer in the list.
    func binding(for id: UUID) -> Binding<ClipListItem>? {
        guard let current = items.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.items.first(where: { $0.id == id }) ?? current },
            set: { updated in
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index] = updated
            }
        )
    }

    /// The "+" tile's action: appends a new clip covering the first few seconds of the
    /// asset (or its full duration if shorter), full-frame crop. The user trims it with
    /// the same inline timeline every other card uses; there's no separate creation UI.
    func addClip() async {
        let duration = await assetDuration() ?? Self.defaultNewClipDuration
        let end = max(min(Self.defaultNewClipDuration, duration), ClipEditorViewModel.minimumClipDuration)
        items.append(ClipListItem(
            window: TrickWindow(startTime: 0, endTime: end),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)))
    }

    private static let defaultNewClipDuration: TimeInterval = 3

    /// Loads the asset's duration once per asset; concurrent callers share the single
    /// in-flight task. `@MainActor`-serialized, so the check-then-set is race-free
    /// (same pattern as `trackGeometry` above).
    func assetDuration() async -> TimeInterval? {
        if durationTask == nil {
            durationTask = Task { [asset] in
                guard let duration = try? await asset.load(.duration) else { return nil }
                let seconds = duration.seconds
                return seconds.isFinite && seconds > 0 ? seconds : nil
            }
        }
        guard let durationTask else { return nil }
        return await durationTask.value
    }

    /// The card thumbnail, loading lazily. Idempotent and safe to call from every card's
    /// `.task`: repeat calls return the cached image, and concurrent calls for the same
    /// card share one decode instead of seeking the same frame twice. A cancelled caller
    /// never cancels the shared decode — the decode runs to completion and the result is
    /// cached, so a card that scrolls off-screen and back within the decode window gets
    /// its thumbnail from the re-fired `.task` instead of a discarded, already-paid-for
    /// decode. (Lingering decodes are intentional: `copyCGImage` is not cancellable, so
    /// cancelling the shared task cannot save the expensive work — it can only throw the
    /// result away from under another waiter.)
    func thumbnail(for item: ClipListItem) async -> CGImage? {
        if let cached = thumbnails[item.id] {
            return cached
        }
        if let running = inFlight[item.id] {
            return await running.value
        }
        let task = Task { [loader, asset, item] in
            await loader.thumbnail(for: item, in: asset)
        }
        inFlight[item.id] = task
        let image = await task.value
        inFlight[item.id] = nil
        if let image = image {
            thumbnails[item.id] = image
        }
        return image
    }
}
