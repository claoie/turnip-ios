import AVFoundation
import SwiftUI

/// The export-confirmation screen's per-clip export, wired to the real pipeline step 7
/// (`ClipExporter`): trims the source video to the window, crops to its rect, and writes
/// an `.mp4` into the screen's scratch directory. Failures surface as
/// `ExportConfirmationError.exportFailed` so the screen's per-clip callout names the
/// step; cancellation propagates untouched so the screen stops the run instead of
/// failing the clip.
///
/// File-scope rather than a member of `ClipListView`: a static method value taken from a
/// `View`-conforming type carries the enclosing type in its thunk, which the Swift 6
/// concurrency checker won't treat as `@Sendable` even when the function itself captures
/// nothing.
private func exportOneClip(
    _ spec: ClipSpec, _ asset: AVAsset, _ directory: URL,
    _ progress: @escaping @Sendable (Double) -> Void
) async throws -> URL {
    do {
        let exported = try await ClipExporter().export(
            spec,
            from: asset,
            to: directory,
            progress: progress)
        return exported.fileURL
    } catch {
        if error is CancellationError { throw error }
        throw ExportConfirmationError.exportFailed(reason: error.localizedDescription)
    }
}

/// The export-confirmation screen's Photos save, wired to `ClipPhotosSaver` (add-only
/// authorization). Failures surface as `ExportConfirmationError.photosSaveFailed` so the
/// per-clip callout names the step. File-scope for the same reason as `exportOneClip`.
private func saveOneClipToPhotos(_ url: URL) async throws {
    do {
        try await ClipPhotosSaver().saveVideo(at: url)
    } catch {
        throw ExportConfirmationError.photosSaveFailed(reason: error.localizedDescription)
    }
}

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)"): a grid of square tiles,
/// one per detected trick window, plus a trailing "+" tile that appends a new clip. Each
/// tile plays its clip inline on tap, draws a read-only timeline over the bottom
/// showing where its window sits in the full source video (not adjustable here — that's
/// what the editor is for), and carries an expand button (straight into the full
/// `ClipEditorView` — "view large" and "edit" are the same entry point, not two icons
/// on the tile) and the keep/discard toggle.
///
/// The processing screen pushes this with the pipeline's output; the export action goes
/// to export confirmation. The back chevron pops to Home rather than to the processing
/// screen, Photos-app style — centered inline title on the same line as the chevron.
/// This view deliberately declares no `NavigationStack` of its own — it lives on the
/// flow's shared stack.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    @StateObject private var playback: ClipPlaybackController
    @State private var showingExport = false
    @State private var expandTarget: ExpandTarget?
    let popToRoot: () -> Void

    init(
        items: [ClipListItem],
        asset: AVAsset,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, asset: asset, loader: loader))
        _playback = StateObject(wrappedValue: ClipPlaybackController(asset: asset))
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
                        playback: playback,
                        onExpand: { expandTarget = ExpandTarget(id: item.id) })
                }
                AddClipTile { Task { await viewModel.addClip() } }
            }
            .padding()
        }
        .navigationTitle("Clips")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // The default back chevron would step back to the processing screen;
            // the flow's "back" is Home, so this screen draws its own chevron —
            // Photos-style, chevron only, no text label.
            ToolbarItem(placement: .navigationBarLeading) {
                BackChevronButton(accessibilityLabel: "Back to Home", action: popToRoot)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(viewModel.allKept ? "Deselect All" : "Select All") {
                    if viewModel.allKept {
                        viewModel.deselectAll()
                    } else {
                        viewModel.selectAll()
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showingExport) {
            ExportConfirmationView(
                items: viewModel.exportConfirmationItems,
                asset: viewModel.sourceAsset,
                exportClip: exportOneClip,
                saveToPhotos: saveOneClipToPhotos,
                popToRoot: popToRoot)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryActionBar(viewModel.exportTitle, isEnabled: viewModel.canExport) {
                showingExport = true
            }
        }
        .fullScreenCover(item: $expandTarget) { target in
            editor(for: target)
        }
        .onChange(of: expandTarget?.id) { _ in
            // The grid's own inline playback shouldn't keep running behind the
            // editor, and shouldn't resume stale audio once the editor closes.
            playback.stop()
        }
    }

    /// The expand button's destination: the full `ClipEditorView` (crop + trim) —
    /// expand goes directly to the editor rather than through an intermediate
    /// full-screen viewer, merging "view large" and "edit" into one entry point.
    /// The editor owns its own back/Delete toolbar and closes itself via
    /// `@Environment(\.dismiss)`, which resets `expandTarget` to `nil`.
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

/// The expand button's presentation target: `UUID` alone isn't `Identifiable`, and
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

/// One triage tile: a square clip surface (thumbnail, or the live inline playback while
/// it's the active clip) with the expand button at the top-leading corner, the
/// keep/discard toggle at the top-trailing corner, and a read-only range timeline
/// overlaid on the bottom edge — all siblings drawn as overlays on the tap-driven media
/// layer rather than nested inside a shared `Button`, so each keeps its own hit target
/// instead of racing the tile's play/pause tap (the bug in the previous pencil-icon
/// button).
private struct ClipCardView: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    @ObservedObject var playback: ClipPlaybackController
    let onExpand: () -> Void

    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?

    private var isActive: Bool { playback.activeItemID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tile
            Text(item.durationLabel)
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
    }

    private var tile: some View {
        GeometryReader { proxy in
            mediaLayer
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { playback.toggle(item) }
                // The UI-test screenshot harness waits on this label to prove the
                // thumbnail fallback actually engaged.
                .accessibilityLabel(
                    thumbnail == nil && !isActive
                        ? "Thumbnail placeholder"
                        : (playback.isPlaying && isActive ? "Pause clip" : "Play clip"))
                .accessibilityAddTraits(.isButton)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) { expandButton }
        .overlay(alignment: .topTrailing) { keepButton }
        .overlay(alignment: .bottom) { trimOverlay }
    }

    @ViewBuilder
    private var mediaLayer: some View {
        if isActive, let player = playback.player {
            BareVideoPlayerView(player: player, videoGravity: .resizeAspectFill)
        } else if let thumbnail {
            // The generator hands back the displayed (upright) frame, so `.up` is exact —
            // no UIKit bridge needed.
            Image(decorative: thumbnail, scale: 1.0, orientation: .up)
                .resizable()
                .scaledToFill()
        } else {
            Color(.quaternarySystemFill)
                .overlay { ProgressView() }
        }
    }

    /// The diameter every top-corner icon circle renders at, kept/discarded or not —
    /// a fixed frame rather than content-driven padding, so swapping the keep button's
    /// icon (or hiding it entirely for the unselected state) can never change its size
    /// relative to the expand button's.
    private static let iconButtonDiameter: CGFloat = 28

    private var expandButton: some View {
        ScrimIconButton(
            systemImage: "arrow.up.left.and.arrow.down.right",
            accessibilityLabel: "Expand clip",
            diameter: Self.iconButtonDiameter,
            font: .caption.weight(.semibold),
            action: onExpand
        )
        .padding(6)
    }

    /// Photos-style selection marker: a solid blue circle with a white checkmark when
    /// kept, the same semi-transparent grey circle the other tile buttons use —
    /// but empty — when discarded. Custom rather than `ScrimIconButton`, since only
    /// this one needs a background color that changes with state.
    private var keepButton: some View {
        Button(action: toggleKeep) {
            ZStack {
                Circle().fill(item.isKept ? Color.accentColor : Color.black.opacity(0.4))
                if item.isKept {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Self.iconButtonDiameter, height: Self.iconButtonDiameter)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(item.isKept ? "Discard clip" : "Keep clip")
    }

    private func toggleKeep() {
        viewModel.toggleKeep(item)
    }

    @ViewBuilder
    private var trimOverlay: some View {
        if let duration {
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
                    isKept: false
                )
            ],
            // AVAsset is abstract and throws at runtime; AVURLAsset is the concrete
            // subclass. The URL resolves to nothing — the preview shows the
            // placeholder tiles, which is the honest fallback.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        )
    }
}
