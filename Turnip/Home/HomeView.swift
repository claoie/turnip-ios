import AVFoundation
import Photos
import SwiftUI

/// Home / Video Gallery per docs/UIUX.md: the entry screen *is* the video picker — a 3-column
/// grid of every video in the Photos library, newest first. Tapping a tile is the "pick" action.
/// The view model is owned by `RootTabView` (shared with the Camera tab, whose finished
/// recordings feed into the same `select(_:)` a tapped tile calls) rather than by this view.
struct HomeView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// Plain reference, not `@ObservedObject`: this view never displays a setting's value,
    /// it only reads `analysisGranularity` at navigation time and hands the store to the
    /// sheet, which observes it directly. `@ObservedObject` here would re-run this view's
    /// whole body — including the video grid's `ForEach` — on every keystroke in the
    /// Settings sheet's album-name field, for a value this view never shows.
    private let settings = TurnipSettingsStore.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            content
                // The wordmark is scroll content (`HomeHeader`), not a bar title, so it
                // scrolls away with the tiles (docs/UIUX.md). Root-only — pushed screens
                // declare their own bars.
                .modifier(HomeNavigationBar())
                .navigationDestination(for: SelectedVideo.self) { video in
                    // A video the camera already analyzed while recording it lands on the
                    // clip list directly. Otherwise the Processing screen shows the picked
                    // video and runs the real detection pipeline on the user's tap, then
                    // pushes the clip list on success — analysis never auto-starts
                    // (docs/UIUX.md § "Processing"). `popToRoot` threads the flow's "back
                    // to Home" action through the pushed screens so their back chevrons
                    // return here instead of stepping back through the flow.
                    if let clips = video.detectedClips {
                        clipList(for: video, clips: clips, asset: video.asset, popToRoot: popToRoot)
                    } else {
                        ProcessingView(
                            video: video,
                            runner: ProcessingPipeline(sampleRate: settings.analysisGranularity),
                            autostart: false,
                            popToRoot: popToRoot,
                            previousVideo: browseAction(for: video, offset: -1),
                            nextVideo: browseAction(for: video, offset: 1),
                            // Renders this screen's browse-in-flight overlay from the same
                            // `Resolution` state `ResolutionBanner` already shows on the grid.
                            // Almost always the swipe this screen just triggered; showing it for
                            // the rare unrelated case too (a camera recording resolving in the
                            // background) is harmless — it just dims an already-paused video.
                            browsingNeighbor: viewModel.resolution,
                            cancelBrowsing: viewModel.cancelSelection,
                            destination: { result, popToRoot in
                                clipList(for: video, clips: result.clips, asset: result.asset, popToRoot: popToRoot)
                            }
                        )
                        // Ties the screen's identity to the video it's showing: without this,
                        // browsing to a neighbor replaces `path`'s top element but SwiftUI can
                        // reuse the existing `ProcessingView`, leaving its `@StateObject` and
                        // player pointed at the video that just left.
                        .id(video.assetIdentifier)
                    }
                }
        }
        .task { await viewModel.start() }
        .alert("Couldn't open video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
    }

    private func popToRoot() {
        viewModel.path = []
    }

    /// The closure Processing's swipe gesture calls for `offset` (`-1` previous, `+1` next) —
    /// nil when `viewModel.hasNeighbor` says there's nothing there, which is what makes the
    /// swipe a no-op at that end of the grid instead of wrapping around. `hasNeighbor` is a
    /// pure read, safe to call here in the view body; the actual browse — which can grow
    /// `viewModel.videos`, a published mutation — happens only once the closure fires.
    private func browseAction(for video: SelectedVideo, offset: Int) -> (() -> Void)? {
        guard viewModel.hasNeighbor(of: video.assetIdentifier, offset: offset) else { return nil }
        return { viewModel.browseToNeighbor(of: video.assetIdentifier, offset: offset) }
    }

    private func clipList(
        for video: SelectedVideo, clips: [ProcessedClip], asset: AVURLAsset, popToRoot: @escaping () -> Void
    ) -> ClipListView {
        ClipListView(
            items: clips.map { ClipListItem(window: $0.window, cropRect: $0.cropRect) },
            asset: asset,
            assetIdentifier: video.assetIdentifier,
            duration: video.duration,
            popToRoot: popToRoot
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .notDetermined:
            // The system permission prompt is up; nothing useful to draw behind it.
            ProgressView()
        case .denied(let restricted):
            VStack(spacing: 0) {
                HomeHeader(onSettingsTapped: { showSettings = true })
                PhotosAccessDeniedView(restricted: restricted)
            }
        case .authorized, .limited:
            VideoGalleryView(viewModel: viewModel, onSettingsTapped: { showSettings = true })
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// Home's title row: the "Turnip" wordmark image (mark + text baked into one asset),
/// centered in a nav-bar-height band, with the settings gear trailing it when
/// `onSettingsTapped` is supplied. Laid out as ordinary content — inside the grid's scroll
/// view, or above a non-scrolling state — rather than as a nav bar title, so both the wordmark
/// and the gear scroll away with the tiles instead of floating fixed over them: a fixed overlay
/// at this corner would otherwise permanently sit over whatever grid tile scrolls underneath it
/// and intercept taps meant for that tile, the way the wordmark itself scrolling away avoids
/// that problem for the header row as a whole. Internal so the DEBUG screenshot harness can
/// render the denied state exactly as Home does.
struct HomeHeader: View {
    /// `nil` renders no gear — every caller except Home's own states (denied and the video
    /// gallery) that can actually reach Settings.
    var onSettingsTapped: (() -> Void)?

    private static let logoHeight: CGFloat = 36
    private static let rowHeight: CGFloat = 44
    /// Drawn smaller than `ScrimIconButton`'s 44 pt default so the visible glyph leaves more
    /// room for the logo in this shared row — the tappable region stays 44×44 regardless,
    /// per `ScrimIconButton`'s own touch-target floor (docs/ACCESSIBILITY.md:94).
    private static let settingsButtonDiameter: CGFloat = 32

    var body: some View {
        Image("TitleLogo")
            .resizable()
            .scaledToFit()
            .frame(height: Self.logoHeight)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            .accessibilityLabel("Turnip")
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .trailing) {
                if let onSettingsTapped {
                    ScrimIconButton(
                        systemImage: "gearshape", accessibilityLabel: "Settings",
                        diameter: Self.settingsButtonDiameter, action: onSettingsTapped)
                        .padding(.trailing)
                        .accessibilityIdentifier("settings-button")
                }
            }
    }
}

/// The grid plus its decorations: a "select more" banner under limited access, and a bottom
/// banner with a cancel button while a tapped video is being fetched. An ordinary full-screen
/// scrollable grid, newest videos first — no landing/reveal state.
struct VideoGalleryView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// Threaded straight to every `HomeHeader()` this view constructs (loading, empty, and grid
    /// states all show one) rather than each state re-deriving its own entry point.
    var onSettingsTapped: (() -> Void)?

    private static let spacing: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.authorization == .limited {
                    LimitedAccessBanner(selectMore: viewModel.presentLimitedLibraryPicker)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let resolution = viewModel.resolution {
                    ResolutionBanner(resolution: resolution, cancel: viewModel.cancelSelection)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            // Not yet the same thing as "no videos" — the first fetch hasn't run.
            VStack(spacing: 0) {
                HomeHeader(onSettingsTapped: onSettingsTapped)
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.videos.isEmpty {
            VStack(spacing: 0) {
                HomeHeader(onSettingsTapped: onSettingsTapped)
                emptyState
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            // The header (with the settings gear, when reachable) is scroll content, not
            // chrome: it leads the grid and leaves the screen with the first row.
            HomeHeader(onSettingsTapped: onSettingsTapped)
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(
                    Array(viewModel.videos.enumerated()), id: \.element.localIdentifier
                ) { index, asset in
                    tile(for: asset, index: index)
                }
            }
            // The floating tab bar overlays this screen rather than reserving its own
            // safe-area space, so without this the bottom row would end up permanently
            // stuck underneath it.
            .padding(.bottom, FloatingTabBarMetrics.clearance)
        }
        // The grid announces its count when VoiceOver enters it — a VoiceOver user
        // otherwise has no sense of how many videos they're swiping through. The
        // ScrollView must be declared an accessibility container: a label on a
        // non-element container is never announced on entry.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gridAccessibilityLabel)
        .accessibilityIdentifier("video-grid")
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
        StatusStateView(
            systemImage: "video.slash",
            title: viewModel.authorization == .limited ? "No videos selected" : "No videos",
            message: viewModel.authorization == .limited
                ? "Turnip can only see the videos you choose. Select some to get started."
                : "Record a tricking session, and it'll show up here."
        )
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

/// Denied / restricted empty state. There's no picker fallback once Home is the gallery, so the
/// only way forward is Settings — unless a restriction means Settings can't help either.
struct PhotosAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        StatusStateView(
            systemImage: "photo.on.rectangle.angled",
            title: "Turnip needs access to your videos",
            message: restricted
                ? "Photos access is restricted on this device, so Turnip can't show your videos."
                : "Turnip finds and trims tricks in recordings from your Photos library. "
                    + "Allow access in Settings to get started."
        ) {
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    .accessibilityIdentifier("open-settings")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("photos-access-denied")
    }
}

/// Home's nav bar: present, transparent, visually empty, and taking no space. On iOS 26 a
/// scroll view's top scroll-edge glass — the soft blur that keeps the status bar legible
/// over tiles scrolling beneath it — is only drawn by a navigation bar that has content,
/// and only blurs (rather than merely dimming) when that content is text. A hidden bar,
/// an empty title, `scrollEdgeEffectStyle` on the scroll view, and a `safeAreaBar`
/// standing in for the bar all leave the status bar dead sharp; a clear color or a
/// `hidden()` text as the principal item gets a dim gradient with no blur; a
/// whitespace title draws stray glyphs. A fully transparent title text is the
/// "content" that makes UIKit draw the real blur, with the bar's own background hidden
/// so nothing else shows. The bar still reserves its band
/// in the safe area, so the content gets that band back: it ignores the top safe area
/// and re-adds only the status bar's share as an inset. The wordmark header then sits
/// directly under the status bar at rest — in the grid and in the non-scrolling states
/// alike, so it doesn't jump when the grid replaces the loading state — and the glass
/// fades in over the band only once tiles scroll under it. Pre-26 there is no glass to
/// anchor, so the bar is hidden outright. Internal so the DEBUG screenshot harness and
/// previews match.
struct HomeNavigationBar: ViewModifier {
    /// The inline bar's height on iOS 26 (measured: the top safe area with the bar minus
    /// the top safe area without it). There is no public constant for it.
    private static let barHeight: CGFloat = 54

    /// Whether the scroll content has moved up past its rest position. With the header
    /// sitting inside the bar's band at rest, UIKit considers the content "under the
    /// bar" from the start and would draw the glass over the wordmark before any scroll;
    /// the effect is held hidden until the content actually moves.
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                content
                    // A GeometryReader lays its child out top-leading; filling it keeps a
                    // lone spinner (the not-yet-determined state) centered.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: max(proxy.safeAreaInsets.top - Self.barHeight, 0))
                    }
                    .ignoresSafeArea(.container, edges: .top)
            }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                } action: { _, scrolled in
                    isScrolled = scrolled
                }
                .scrollEdgeEffectHidden(!isScrolled, for: .top)
                // Inline, or the root bar lays out for a large title and reserves that
                // band too.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // The wordmark header already announces "Turnip" as the screen's
                        // header, so this stays out of the accessibility tree.
                        Text("Turnip")
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content.toolbar(.hidden, for: .navigationBar)
        }
    }
}

#Preview("Denied") {
    NavigationStack {
        VStack(spacing: 0) {
            HomeHeader()
            PhotosAccessDeniedView(restricted: false)
        }
        .modifier(HomeNavigationBar())
    }
    .preferredColorScheme(.dark)
}

#Preview("Restricted") {
    NavigationStack {
        VStack(spacing: 0) {
            HomeHeader()
            PhotosAccessDeniedView(restricted: true)
        }
        .modifier(HomeNavigationBar())
    }
    .preferredColorScheme(.dark)
}
