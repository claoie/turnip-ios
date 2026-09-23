import AVFoundation
import SwiftUI
import UIKit

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)"): a grid of square tiles
/// — the original video first, then one per detected trick window, then a trailing
/// "+" tile that appends a new clip. Each tile autoplay-loops its window inline
/// (accessibility permitting) so the grid reads like a wall of tiny previews rather
/// than static frames, draws a read-only timeline over the bottom showing where its
/// window sits in the full source video (not adjustable here — that's what the
/// editor is for, and the original tile has none since its window is the whole
/// video), and carries the trash button. Tapping a derived clip's tile opens the
/// full `ClipEditorView` directly — "view large" and "edit" are the same entry
/// point, not a separate icon; the original tile isn't tappable, since editing the
/// source video isn't a thing this screen does.
///
/// "Done" exports and saves every non-trashed derived clip to Photos, deletes the
/// original from Photos if its tile was trashed, and pops back to Home — there is no
/// separate export/confirmation screen.
///
/// The processing screen pushes this with the pipeline's output. The back chevron
/// pops to Home rather than to the processing screen, Photos-app style — centered
/// inline title on the same line as the chevron. This view deliberately declares no
/// `NavigationStack` of its own — it lives on the flow's shared stack.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    @State private var expandTarget: ExpandTarget?
    let popToRoot: () -> Void

    init(
        items: [ClipListItem],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, asset: asset, assetIdentifier: assetIdentifier,
            duration: duration, loader: loader))
        self.popToRoot = popToRoot
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .top),
                    GridItem(.flexible(), alignment: .top)
                ],
                spacing: 16
            ) {
                ForEach(viewModel.items) { item in
                    ClipCardView(
                        item: item,
                        viewModel: viewModel,
                        isSuspended: expandTarget != nil,
                        onOpen: item.isOriginal ? nil : { expandTarget = ExpandTarget(id: item.id) })
                }
                AddClipTile { Task { await viewModel.addClip() } }
            }
            .padding()
        }
        .disabled(viewModel.isSaving)
        .navigationTitle("Clips")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // The grid runs edge-to-edge under the status bar/nav bar; without hiding the
        // bar's own background, its blur would opaque out the tiles underneath.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // The default back chevron would step back to the processing screen;
            // the flow's "back" is Home, so this screen draws its own chevron —
            // Photos-style, chevron only, no text label.
            ToolbarItem(placement: .navigationBarLeading) {
                BackChevronButton(accessibilityLabel: "Back to Home", action: popToRoot)
                    .disabled(viewModel.isSaving)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryActionBar("Done", isEnabled: !viewModel.isSaving) {
                Task {
                    if await viewModel.save() {
                        popToRoot()
                    }
                }
            }
        }
        .overlay {
            if viewModel.isSaving {
                savingOverlay
            }
        }
        .alert("Couldn't save clips", isPresented: saveFailurePresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.saveFailureMessage ?? "")
        }
        .fullScreenCover(item: $expandTarget) { target in
            editor(for: target)
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ProgressView {
                Text("Saving to Photos…")
            }
            .tint(.white)
            .foregroundStyle(.white)
        }
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(
            get: { viewModel.saveFailureMessage != nil },
            set: { if !$0 { viewModel.saveFailureMessage = nil } }
        )
    }

    /// The tile tap's destination: the full `ClipEditorView` (crop + trim) — tapping
    /// goes directly to the editor rather than through an intermediate full-screen
    /// viewer, merging "view large" and "edit" into one entry point. The editor owns
    /// its own back/Delete toolbar and closes itself via `@Environment(\.dismiss)`,
    /// which resets `expandTarget` to `nil` — each tile's `isSuspended` flag (derived
    /// from `expandTarget`) then lets its player resume.
    @ViewBuilder
    private func editor(for target: ExpandTarget) -> some View {
        if let itemBinding = viewModel.binding(for: target.id) {
            NavigationStack {
                ClipEditorView(
                    source: viewModel.editorSource(for: itemBinding.wrappedValue),
                    onCommit: { result in viewModel.applyEditorResult(result, to: target.id) },
                    onDelete: { viewModel.delete(target.id) }
                )
            }
        }
    }
}

/// The tapped tile's presentation target: `UUID` alone isn't `Identifiable`, and
/// `fullScreenCover(item:)` needs one to know which clip to open (and to dismiss when
/// it goes back to `nil`).
private struct ExpandTarget: Identifiable {
    let id: UUID
}

/// The "+" tile: a grey square with a centered plus sign, appended after every clip
/// card. Tapping it appends a new full-frame clip at the start of the asset (`docs/UIUX.md`
/// § "Clip List (triage)"), which the user then trims like any other card.
private struct AddClipTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemFill))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add clip")
    }
}

/// One triage tile: a square clip surface (an autoplay-looping preview layered over its
/// poster thumbnail, so there's no blank flash while the loop's player becomes ready)
/// with the trash button at the top-trailing corner and, for a derived clip, a
/// read-only range timeline overlaid on the bottom edge — siblings drawn as overlays
/// on the tap-driven media layer rather than nested inside a shared `Button`, so each
/// keeps its own hit target instead of racing the tile's tap.
///
/// Owns its own `AVQueuePlayer` + `AVPlayerLooper` rather than sharing one across the
/// grid: every visible tile loops simultaneously, which a single shared player can't
/// do. `LazyVGrid` mounting/unmounting off-screen tiles bounds how many of these run
/// concurrently to what's on (or near) screen.
private struct ClipCardView: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    /// True while the full-screen editor is up, per `ClipListView.expandTarget`. The
    /// editor's `fullScreenCover` doesn't reliably fire `onDisappear` on the tiles
    /// behind it, so this is the signal that actually pauses them instead.
    let isSuspended: Bool
    /// Opens the editor on this clip, or `nil` for the original item — its tile has
    /// no tap action.
    let onOpen: (() -> Void)?

    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    /// A `@State` mirror of `isSuspended`. `startPlayback()` reads this rather than the
    /// `let` property directly: SwiftUI can invoke `.onChange(of:)`'s action closure with
    /// a `self` captured from an earlier render than the one that produced the new value,
    /// so `self.isSuspended` inside a method called from that closure can read stale —
    /// observed as every tile bailing out of resume with `suspended` still `true` right
    /// after the editor's `fullScreenCover` reported it as `false`. `@State`'s storage is
    /// identity-bound rather than render-bound, so it reads live regardless of which
    /// snapshot of `self` touches it — the same property already relied on for `player`.
    @State private var suspended = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tile
            Text(item.isOriginal ? "Original video" : item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // The thumbnail decode and the shared asset duration each dedupe/cache in
            // the view model, so a re-fired `.task` (e.g. scrolling the card off-screen
            // and back) joins the work already done instead of repeating it.
            async let image = viewModel.thumbnail(for: item)
            async let assetDuration = viewModel.assetDuration()
            thumbnail = await image
            duration = await assetDuration
        }
        .onAppear {
            suspended = isSuspended
            startPlayback()
        }
        .onDisappear { teardownPlayback() }
        .onChange(of: isSuspended) { newValue in
            suspended = newValue
            if newValue {
                player?.pause()
            } else {
                startPlayback()
            }
        }
        .onChange(of: item.window) { _ in
            // `ForEach` keys tiles by `item.id`, so an editor commit that changes the
            // window reuses this same tile's identity — and its player/looper — rather
            // than creating a fresh one. Without rebuilding here, the loop would keep
            // playing the pre-edit range forever.
            teardownPlayback()
            startPlayback()
        }
    }

    private var tile: some View {
        GeometryReader { proxy in
            mediaLayer
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onOpen?() }
                // The UI-test screenshot harness waits on this label to prove the
                // thumbnail fallback actually engaged.
                .accessibilityLabel(tileAccessibilityLabel)
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { trashButton }
        .overlay(alignment: .bottom) { trimOverlay }
        .opacity(item.isTrashed ? 0.4 : 1)
    }

    private var tileAccessibilityLabel: String {
        guard thumbnail != nil else { return "Thumbnail placeholder" }
        return item.isOriginal ? "Original video" : "Open clip"
    }

    @ViewBuilder
    private var mediaLayer: some View {
        ZStack {
            if let thumbnail {
                // The generator hands back the displayed (upright) frame, so `.up` is
                // exact — no UIKit bridge needed. Drawn under the player unconditionally
                // as a poster: the looper's item takes a moment to become ready, and
                // without this the tile would show black until it does.
                Image(decorative: thumbnail, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.quaternarySystemFill)
                    .overlay { ProgressView() }
            }
            if let player {
                BareVideoPlayerView(player: player, videoGravity: .resizeAspectFill)
            }
        }
    }

    /// Builds the tile's own looping player on first need and starts it, unless the
    /// system's video-autoplay setting is off (`docs/ACCESSIBILITY.md`'s Clip List
    /// checklist rules out auto-playing loops in that case, so the tile just shows its
    /// static poster) or the editor is currently covering the grid. Safe to call
    /// repeatedly — an existing player is just resumed.
    private func startPlayback() {
        guard UIAccessibility.isVideoAutoplayEnabled, !suspended else { return }
        if player == nil {
            let templateItem = AVPlayerItem(sdrAsset: viewModel.sourceAsset)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            let timeRange = CMTimeRange(
                start: CMTime(seconds: item.window.startTime, preferredTimescale: 600),
                end: CMTime(seconds: item.window.endTime, preferredTimescale: 600))
            looper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem, timeRange: timeRange)
            player = queuePlayer
        }
        player?.play()
    }

    /// Releases the tile's decoder entirely rather than just pausing — called on
    /// `onDisappear`, so a tile scrolled far off-screen doesn't keep holding a decode
    /// pipeline open behind ones that are actually visible.
    private func teardownPlayback() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
    }

    /// The diameter every top-corner icon circle renders at.
    private static let iconButtonDiameter: CGFloat = 28

    /// The per-tile trash button: a solid red circle while trashed, the same
    /// semi-transparent grey circle the other tile buttons use otherwise. For the
    /// original item, tapping it is the reversible toggle that tells "Done" to
    /// delete the source video from Photos; for a derived clip, tapping it removes
    /// the tile from the grid immediately, with no restore.
    private var trashButton: some View {
        Button(action: trash) {
            ZStack {
                Circle().fill(item.isTrashed ? Color.red : Color.black.opacity(0.4))
                Image(systemName: "trash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.iconButtonDiameter, height: Self.iconButtonDiameter)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(item.isTrashed ? "Restore clip" : "Trash clip")
    }

    private func trash() {
        viewModel.trash(item)
    }

    @ViewBuilder
    private var trimOverlay: some View {
        if let duration, !item.isOriginal {
            ClipRangeTimelineView(window: item.window, duration: duration)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.35))
        }
    }
}

#Preview {
    NavigationStack {
        ClipListView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
                ),
                ClipListItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                    isTrashed: true
                )
            ],
            // AVAsset is abstract and throws at runtime; AVURLAsset is the concrete
            // subclass. The URL resolves to nothing — the preview shows the
            // placeholder tiles, which is the honest fallback.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15
        )
    }
    .preferredColorScheme(.dark)
}
