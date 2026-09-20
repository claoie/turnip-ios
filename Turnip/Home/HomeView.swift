import Photos
import SwiftUI

/// Home / Video Gallery per docs/UIUX.md: the entry screen *is* the video picker — a 3-column
/// grid of every video in the Photos library. Tapping a tile is the "pick" action.
struct HomeView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @State private var showCamera = false
    /// Collapsed (the resting/landing state — logo centered, no title, one row peeking at
    /// the top) vs. expanded (swiped down into a full-screen scrollable grid with the
    /// title bar back). The title bar itself is driven by this, not just the grid's own
    /// layout, so it has to live here rather than inside `VideoGalleryView`.
    @State private var isExpanded = false

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            content
                .navigationTitle("Turnip")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(isExpanded ? .visible : .hidden, for: .navigationBar)
                .fullScreenCover(isPresented: $showCamera) {
                    CameraCaptureView(onFinished: handleRecorded)
                }
                .navigationDestination(for: SelectedVideo.self) { video in
                    // The Processing screen shows the picked video and runs the real
                    // detection pipeline on the user's tap, then pushes the clip list
                    // on success — analysis never auto-starts (docs/UIUX.md
                    // § "Processing"). `popToRoot` threads the flow's "back to Home"
                    // action through the pushed screens so their back chevrons return
                    // here instead of stepping back through the flow.
                    ProcessingView(
                        video: video,
                        autostart: false,
                        popToRoot: { viewModel.path = [] },
                        destination: { result, popToRoot in
                            ClipListView(
                                items: result.clips.map {
                                    ClipListItem(window: $0.window, cropRect: $0.cropRect)
                                },
                                asset: result.asset,
                                popToRoot: popToRoot
                            )
                        }
                    )
                }
        }
        .task { await viewModel.start() }
        .alert("Couldn't open video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .notDetermined:
            // The system permission prompt is up; nothing useful to draw behind it.
            ProgressView()
        case .denied(let restricted):
            PhotosAccessDeniedView(restricted: restricted)
        case .authorized, .limited:
            VideoGalleryView(
                viewModel: viewModel, isExpanded: $isExpanded, onSwipeUpToRecord: { showCamera = true })
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    /// A recording finished: save it to Photos (reusing the same `ClipPhotosSaver` the
    /// export flow already uses), then hand the resulting `PHAsset` to `viewModel.select`
    /// — the exact call a tapped gallery tile makes. That pushes it onto the shared
    /// `NavigationStack` path and lands on `ProcessingView`'s idle "Start analysis" state
    /// with no new navigation code.
    private func handleRecorded(_ fileURL: URL) {
        showCamera = false
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let identifier = try await ClipPhotosSaver().saveVideo(at: fileURL)
                guard let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject else { return }
                viewModel.select(asset)
            } catch {
                viewModel.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

/// The grid plus its decorations: a "select more" banner under limited access, a bottom
/// banner with a cancel button while a tapped video is being fetched, and — when nothing
/// is being fetched — the "swipe up to take a video" affordance that starts the camera.
///
/// Two states, not one screen: **collapsed** (the landing state — no title bar, the app
/// mark centered on screen, one row of the newest videos pinned at the true top edge,
/// growing live as the user swipes down) and **expanded** (committed into, past the reveal
/// threshold) — a normal full-screen scrollable grid with the title bar back.
struct VideoGalleryView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel
    @Binding var isExpanded: Bool
    let onSwipeUpToRecord: () -> Void

    private static let spacing: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    /// Drives the landing animation: the collapsed row slides down from off the top edge
    /// into its resting position once, on first appearance.
    @State private var hasAppeared = false
    @State private var hasInitialized = false
    /// How far into the swipe-down-to-expand reveal the user currently is, live while
    /// dragging: 0 = collapsed height, 1 = fully expanded height. Settles back to exactly
    /// 0 or 1 once the gesture ends.
    @State private var revealProgress: CGFloat = 0

    /// How many points of downward drag equal a full reveal.
    private static let revealDragDistance: CGFloat = 240
    /// How many tiles the *collapsed/growing* grid ever renders — capped (rather than the
    /// whole library) since it isn't inside a `ScrollView` and so isn't lazy. Comfortably
    /// covers any phone screen's worth of rows; the real, fully lazy `ScrollView` grid
    /// takes over once `isExpanded` settles true.
    private static let collapsedTileCap = 24

    var body: some View {
        GeometryReader { proxy in
            let tileSize = (proxy.size.width - CGFloat(columns.count - 1) * Self.spacing)
                / CGFloat(columns.count)
            let rowHeight = tileSize + Self.spacing

            // The logo, the landing slide, and (via the bottom bar below) the "swipe up"
            // text must all render regardless of load state — an empty or not-yet-loaded
            // library is exactly when a user most needs the record affordance, and it must
            // not depend on the grid ever having tiles to animate in.
            if isExpanded {
                expandedContent(height: proxy.size.height)
            } else {
                ZStack {
                    // Centered on the *whole* container would sit visually high — the
                    // peeking row above eats into that space but nothing below balances
                    // it, since the bottom bar is already excluded via `safeAreaInset`.
                    // Offsetting by half the row's height centers the mark in the space
                    // actually left below the row instead.
                    Image("SplashLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .offset(y: rowHeight / 2)
                    VStack(spacing: 0) {
                        growingGrid(
                            rowHeight: rowHeight, fullHeight: proxy.size.height,
                            entryOffset: proxy.size.height)
                        Spacer(minLength: 0)
                    }
                }
                // The whole landing page responds to the swipe, not just the tile row or
                // the bottom bar — the bar keeps its own copy of the up-swipe below since
                // it lives outside this content in a `safeAreaInset` and this gesture
                // can't reach that area.
                .contentShape(Rectangle())
                .gesture(collapsedDragGesture)
            }
        }
        // Collapsed: content goes edge-to-edge behind the status bar (there's no nav bar
        // reserving that space). Expanded: the nav bar is back, so the safe area has to be
        // respected again or the title renders on top of the grid instead of above it.
        .ignoresSafeArea(edges: isExpanded ? [] : .top)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            withAnimation(.easeOut(duration: 0.6)) {
                hasAppeared = true
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if viewModel.authorization == .limited {
                LimitedAccessBanner(selectMore: viewModel.presentLimitedLibraryPicker)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let resolution = viewModel.resolution {
                ResolutionBanner(resolution: resolution, cancel: viewModel.cancelSelection)
            } else {
                SwipeUpToRecordBar(onSwipeUp: onSwipeUpToRecord)
                    .opacity(hasAppeared ? 1 : 0)
            }
        }
    }

    /// The collapsed/growing grid: not a `ScrollView` at all — up to `collapsedTileCap`
    /// videos in a plain `LazyVGrid`, non-interactive. A `ScrollView` keeps its own pan
    /// gesture recognizer even while `.scrollDisabled`, and that recognizer beat a sibling
    /// `DragGesture` for the touch far too often for swipe-down-to-expand to fire
    /// reliably, so this state avoids having a `ScrollView` there to compete with in the
    /// first place. Its own height tracks `revealProgress` live: dragging down grows it
    /// from `rowHeight` toward `fullHeight`, `.clipped()` to reveal more rows as it grows
    /// rather than stretching the ones already visible. Tiles aren't tappable here either
    /// — nothing asks for opening a video before the grid is expanded.
    private func growingGrid(rowHeight: CGFloat, fullHeight: CGFloat, entryOffset: CGFloat) -> some View {
        let height = rowHeight + (fullHeight - rowHeight) * revealProgress
        // Reverses the order of *rows*, not of assets — each row keeps its own
        // left-to-right order, so the newest row (last after this reversal) reads
        // exactly like the first row of `expandedGrid`, just relocated to the
        // bottom of this frame.
        let tiles = Self.rowReversed(
            Array(viewModel.videos.prefix(Self.collapsedTileCap)), columns: columns.count)
        return LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(tiles, id: \.localIdentifier) { asset in
                VideoTileView(
                    asset: asset,
                    thumbnails: viewModel.thumbnails,
                    revision: viewModel.thumbnails.revision(for: asset),
                    isResolving: viewModel.isResolving(asset),
                    downloadProgress: viewModel.downloadProgress(for: asset)
                )
            }
        }
        // The frame's own top edge is pinned at the screen's top edge (see the
        // enclosing `VStack`), so growing its height extends the bottom edge
        // downward. Bottom-aligning the (taller, always fully laid out) grid inside
        // it means the newest row rides that bottom edge down while older rows
        // reveal from above.
        .frame(height: max(height, rowHeight), alignment: .bottom)
        .clipped()
        .offset(y: hasAppeared ? 0 : -entryOffset)
        .opacity(hasAppeared ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gridAccessibilityLabel)
        .accessibilityIdentifier("video-grid")
        .accessibilityAddTraits(.isButton)
        // VoiceOver has no swipe gesture equivalent on a plain container; a double-tap
        // action is the only way it can reach the expanded grid at all.
        .accessibilityAction { expand() }
    }

    /// One gesture for the whole landing page, live-tracking on the way down (the grid
    /// grows with the finger, matching "tiles come down as I swipe" rather than a sudden
    /// cross-fade once released) and threshold-based on the way up (unchanged — already
    /// felt right as a plain swipe-to-open-camera).
    private var collapsedDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dy = value.translation.height
                revealProgress = dy > 0 ? min(1, dy / Self.revealDragDistance) : 0
            }
            .onEnded { value in
                let dy = value.translation.height
                if dy > 0 {
                    if revealProgress > 0.35 {
                        expand()
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) { revealProgress = 0 }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { revealProgress = 0 }
                    if dy < -40 {
                        onSwipeUpToRecord()
                    }
                }
            }
    }

    /// Commits to the expanded grid: finishes the live reveal to full height, then swaps
    /// in the real `ScrollView`-backed grid once that animation has visually landed — the
    /// swap itself has to wait, or the still-mid-drag frame would jump to a `ScrollView`
    /// that hasn't settled yet.
    private func expand() {
        withAnimation(.easeOut(duration: 0.3)) {
            revealProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isExpanded = true
        }
    }

    /// Everything the *expanded* state can show — loading, empty, or the real grid. Kept
    /// separate from the collapsed branch so the logo/landing-animation/bottom-bar shell
    /// above renders unconditionally, independent of whether the library has loaded yet.
    @ViewBuilder
    private func expandedContent(height: CGFloat) -> some View {
        if !viewModel.hasLoaded {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.videos.isEmpty {
            emptyState
        } else {
            expandedGrid(height: height)
        }
    }

    /// The expanded, full-screen scrollable grid — ordinary Photos-picker browsing, every
    /// video, tap to select. Oldest-to-newest top-to-bottom, matching `growingGrid`, and
    /// opened scrolled to the newest (bottom) row rather than the oldest.
    ///
    /// A `ScrollViewReader.scrollTo` on first appear (tried first) reliably opened at the
    /// right row, but forces a `LazyVGrid` to realize far more of a 60-tile page than the
    /// handful actually on screen, which is exactly the kind of thing that shows up as
    /// scroll lag. A `scaleEffect(y: -1)` flip (on the `ScrollView` and each un-flipped
    /// tile) gets the same opened-at-the-bottom result for free — native offset 0 already
    /// *is* the visual bottom, so nothing has to scroll or force-realize anything — and
    /// paging in another page lands past the native content's far edge (now the visual
    /// top, off-screen) rather than shoving the current scroll position down.
    private func expandedGrid(height: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(
                    Array(viewModel.videos.enumerated()), id: \.element.localIdentifier
                ) { index, asset in
                    tile(for: asset, index: index)
                        .scaleEffect(x: 1, y: -1)
                }
            }
        }
        .scaleEffect(x: 1, y: -1)
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gridAccessibilityLabel)
        .accessibilityIdentifier("video-grid")
    }

    /// Groups `assets` into rows of `columns` and reverses the row order while keeping
    /// each row's own order intact — unlike reversing the flat array, which would also
    /// mirror left-to-right order within what was the last row.
    private static func rowReversed<T>(_ assets: [T], columns: Int) -> [T] {
        stride(from: 0, to: assets.count, by: columns)
            .map { Array(assets[$0..<min($0 + columns, assets.count)]) }
            .reversed()
            .flatMap { $0 }
    }

    private func tile(for asset: PHAsset, index: Int) -> some View {
        Button {
            viewModel.select(asset)
        } label: {
            VideoTileView(
                asset: asset,
                thumbnails: viewModel.thumbnails,
                revision: viewModel.thumbnails.revision(for: asset),
                isResolving: viewModel.isResolving(asset),
                downloadProgress: viewModel.downloadProgress(for: asset)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.resolution != nil)
        .onAppear { viewModel.tileAppeared(at: index) }
    }

    /// "1 video" / "N videos", announced on entering the grid. Kept as a separate property
    /// (rather than inline) so the singular/plural branch is visible and greppable.
    private var gridAccessibilityLabel: String {
        let count = viewModel.videos.count
        if count == 1 {
            return String(localized: "1 video")
        }
        return String(localized: "\(count) videos")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(viewModel.authorization == .limited ? "No videos selected" : "No videos")
                .font(.title3.weight(.semibold))
            Text(
                viewModel.authorization == .limited
                    ? "Turnip can only see the videos you choose. Select some to get started."
                    : "Record a tricking session, and it'll show up here."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LimitedAccessBanner: View {
    let selectMore: () -> Void

    var body: some View {
        HStack {
            Text("Turnip can only see the videos you've selected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select More…", action: selectMore)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("select-more-videos")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("limited-access-banner")
    }
}

private struct ResolutionBanner: View {
    let resolution: VideoLibraryViewModel.Resolution
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                if let progress = resolution.downloadProgress {
                    Text("Downloading from iCloud…")
                        .font(.subheadline)
                    ProgressView(value: progress)
                } else {
                    Text("Preparing video…")
                        .font(.subheadline)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .accessibilityIdentifier("cancel-video-resolution")
        }
        .padding()
        .background(.bar)
        .accessibilityIdentifier("resolution-banner")
    }
}

/// The bottom affordance inviting the user to record: an up-arrow, an instruction, and a
/// swipe-up gesture scoped to this bar specifically (not the whole screen) so it never
/// competes with the grid `ScrollView`'s own vertical scroll gesture.
private struct SwipeUpToRecordBar: View {
    let onSwipeUp: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up")
                .font(.footnote.weight(.semibold))
            Text("Swipe up to take a video")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.black)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -40 {
                        onSwipeUp()
                    }
                }
        )
        .accessibilityIdentifier("swipe-up-to-record")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Take a video")
        // VoiceOver has no swipe gesture equivalent here; a double-tap action is the only
        // way it can start the camera at all.
        .accessibilityAction { onSwipeUp() }
    }
}

/// Denied / restricted empty state. There's no picker fallback once Home is the gallery, so the
/// only way forward is Settings — unless a restriction means Settings can't help either.
struct PhotosAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Turnip needs access to your videos")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(
                restricted
                    ? "Photos access is restricted on this device, so Turnip can't show your videos."
                    : "Turnip finds and trims tricks in recordings from your Photos library. "
                        + "Allow access in Settings to get started."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    .accessibilityIdentifier("open-settings")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("photos-access-denied")
    }
}

#Preview("Denied") {
    NavigationStack {
        PhotosAccessDeniedView(restricted: false)
            .navigationTitle("Turnip")
    }
}

#Preview("Restricted") {
    NavigationStack {
        PhotosAccessDeniedView(restricted: true)
            .navigationTitle("Turnip")
    }
}
