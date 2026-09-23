import AVFoundation
import SwiftUI

/// The pipeline progress screen (`docs/UIUX.md` § "Processing").
///
/// Pushed onto the flow's shared `NavigationStack` when a video is picked. It does *not*
/// start the pipeline on appear: the idle state fills the screen with the picked video
/// (no native playback chrome — a thin scrub bar draws over the bottom) and a manual
/// "Start analysis" button — black background, no title, Photos-app look. Once started
/// it shows real per-frame progress ("Analyzing frame 400 of 1,200"), and on success
/// navigates to `destination` with the detected clips. Empty
/// and error states stay on this screen with a way back. Like the other pushed screens,
/// it declares no `NavigationStack` of its own.
///
/// The success destination is injected rather than hardcoded to the clip list, so
/// `Processing` never depends on `ClipList`'s view type (`ClipListView`): the screen
/// that pushes this one supplies `destination`. The destination also receives
/// `popToRoot` — the flow's "back to Home" action — so its back button can skip this
/// screen instead of stepping back through the flow.
struct ProcessingView<Destination: View>: View {
    let video: SelectedVideo
    let destination: (ProcessingResult, @escaping () -> Void) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    /// Home passes `false` too: analysis starts from the idle state's button, never
    /// automatically.
    let autostart: Bool
    /// Pops the flow's navigation stack back to Home. Threaded into the success
    /// destination so its back button returns to the start of the flow.
    let popToRoot: () -> Void
    /// Browses to the previous/next video in Home's grid order, swiping right/left over the
    /// screen respectively — nil at either end of the grid, where the swipe is a no-op instead
    /// of wrapping around. Both are nil in previews and the screenshot harness, which have no
    /// grid to browse. The gesture itself, not this nilness, is what disables the swipe while
    /// a run is in flight (`isAnalyzing`), since a swipe mid-run must not abandon it.
    let previousVideo: (() -> Void)?
    let nextVideo: (() -> Void)?
    /// A browsed-to neighbor's resolution state — non-nil blocks the screen with the same
    /// determinate progress `ResolutionBanner` already renders on the grid (`Home`), so the
    /// swipe that triggered it doesn't just look ignored, and a second swipe here is a
    /// deliberate no-op rather than a silently dropped one (`VideoLibraryViewModel`'s own
    /// `resolution == nil` guard drops it either way; this only makes that visible).
    let browsingNeighbor: VideoLibraryViewModel.Resolution?
    /// Cancels a browse in progress. Nil (never shown) in previews and the screenshot harness.
    let cancelBrowsing: (() -> Void)?

    @StateObject private var viewModel: ProcessingViewModel
    @State private var player: AVPlayer?
    /// The frame size as the player shows it (display orientation), loaded once in
    /// `.task` alongside the player — this view owns the player, so it owns the geometry
    /// the pose overlay needs to land on it too. Same computation as
    /// `ClipEditorViewModel.displayedSize`/`PoseDiagnosticViewModel.displaySize`.
    @State private var displaySize: CGSize?
    /// Seek coalescing for the progress-driven scrub: `ProgressReportClock` fires up to
    /// 10 times a second, and issuing an exact-tolerance seek per report would queue up
    /// keyframe-to-frame decodes on the same file the pipeline's own `AVAssetReader` is
    /// reading, slowing the very run the screen is showing. Only one seek is ever in
    /// flight; a report that lands mid-seek just replaces the pending target.
    @State private var pendingSeekTime: TimeInterval?
    @State private var isSeeking = false
    @Environment(\.dismiss) private var dismiss

    init(
        video: SelectedVideo,
        runner: any ProcessingRunning = ProcessingPipeline(),
        autostart: Bool = true,
        popToRoot: @escaping () -> Void = {},
        previousVideo: (() -> Void)? = nil,
        nextVideo: (() -> Void)? = nil,
        browsingNeighbor: VideoLibraryViewModel.Resolution? = nil,
        cancelBrowsing: (() -> Void)? = nil,
        destination: @escaping (ProcessingResult, @escaping () -> Void) -> Destination
    ) {
        self.video = video
        self.autostart = autostart
        self.popToRoot = popToRoot
        self.previousVideo = previousVideo
        self.nextVideo = nextVideo
        self.browsingNeighbor = browsingNeighbor
        self.cancelBrowsing = cancelBrowsing
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .processing:
                videoStage
            case .empty:
                // `StatusStateView` sizes to its own content otherwise, and the swipe's hit
                // region needs the full screen, the same as every other consumer of this view
                // (`HomeView`'s empty grid and denied states apply the same frame externally).
                // `.ignoresSafeArea()` extends that hit region under the home-indicator strip
                // too, matching `videoStage`'s own `Color.black.ignoresSafeArea()` base — scoped
                // to these three branches rather than the whole `Group`, so it can't change what
                // safe area `videoStage`'s own `.safeAreaInset` insets its bottom bar from.
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            case .failed(let message):
                errorState(message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            case .succeeded:
                // Covered by the pushed destination; only visible when navigating back here.
                Text("Analysis complete.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        // One attachment, covering every branch above (each already reports a full-screen
        // frame) plus the safe-area-inset content `videoStage` adds below its own video area —
        // see this gesture's own doc comment for why a single high-priority attachment this
        // high in the tree is safe rather than swallowing `VideoScrubBar`'s own drag.
        .highPriorityGesture(videoSwipeGesture)
        // A neighbor resolving from a swipe blocks the whole screen, not just the video area —
        // `browsingOverlay` carries its own separate attachment of the same gesture, since
        // `.overlay` content sits alongside this view rather than inside it.
        .overlay {
            if let browsingNeighbor {
                browsingOverlay(browsingNeighbor)
            }
        }
        .navigationBarBackButtonHidden(isAnalyzing)
        .toolbar {
            if isAnalyzing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
            }
        }
        .navigationDestination(isPresented: $viewModel.isShowingClips) {
            if let result = viewModel.result {
                destination(result, popToRoot)
            }
        }
        .task {
            if player == nil {
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(sdrAsset: video.asset))
                player = newPlayer
                // Autoplay on arrival: opening this screen from a video tile is the
                // user's play action, Photos-app style — no separate tap needed.
                newPlayer.play()
            }
            if displaySize == nil,
               let track = try? await video.asset.loadTracks(withMediaType: .video).first,
               let naturalSize = try? await track.load(.naturalSize),
               let preferredTransform = try? await track.load(.preferredTransform) {
                displaySize = ClipEditorViewModel.displayedSize(
                    naturalSize: naturalSize, preferredTransform: preferredTransform)
            }
            if autostart {
                viewModel.start(video: video)
            }
        }
        .onChange(of: currentProgress?.timestamp) { newValue in
            guard let newValue, let player else { return }
            requestSeek(to: newValue, on: player)
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// The in-flight run's latest progress report, or `nil` outside `.processing` — the
    /// scrub/overlay's single read of `viewModel.state`'s associated value.
    private var currentProgress: ProcessingProgress? {
        if case .processing(let progress) = viewModel.state { return progress }
        return nil
    }

    /// Queues a scrub to `time`, coalescing with any seek already in flight (see the
    /// `pendingSeekTime` doc comment). Also pauses the player: once analysis is driving
    /// the picture, free-running playback would fight the scrub on every report.
    private func requestSeek(to time: TimeInterval, on player: AVPlayer) {
        player.pause()
        pendingSeekTime = time
        guard !isSeeking else { return }
        isSeeking = true
        performNextSeek(on: player)
    }

    private func performNextSeek(on player: AVPlayer) {
        guard let time = pendingSeekTime else {
            isSeeking = false
            return
        }
        pendingSeekTime = nil
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { _ in
            Task { @MainActor in performNextSeek(on: player) }
        }
    }

    /// Back/Cancel track the *processing* state rather than `viewModel.isRunning`: idle is
    /// this screen's resting state now (analysis starts manually), so it keeps the default
    /// back chevron to Home. `isRunning` still counts idle as running — the pipeline's
    /// tests lean on that — so it can't drive this.
    private var isAnalyzing: Bool {
        if case .processing = viewModel.state { return true }
        return false
    }

    /// How far a drag has to travel before it counts as a page swipe rather than an
    /// incidental touch on the video. Computed, not a stored constant: `ProcessingView` is
    /// generic over `Destination`, and Swift doesn't allow static stored properties on a
    /// generic type.
    private static var swipeThreshold: CGFloat { 60 }

    /// A right drag browses to the previous video, a left drag to the next — same mapping
    /// as `MainTab`'s Home/Camera pages. Disabled while a run is in flight (a swipe must not
    /// abandon it) or while a previously-triggered browse is still resolving; a swipe with no
    /// neighbor to go to (nil `previousVideo`/`nextVideo` at either end of the grid) is a
    /// no-op regardless, via `browse(_:)`'s own guard.
    ///
    /// `body` attaches this once, as high in the tree as the screen's content goes, rather than
    /// separately on every sub-region: this view sits inside the app's own page-style `TabView`
    /// (`RootTabView`), whose horizontal swipe would otherwise win the recognition race
    /// anywhere this gesture doesn't reach and switch tabs to Camera instead of browsing videos
    /// here — including a swipe starting at the leading edge, so this also supersedes the
    /// system's interactive edge-swipe-to-pop (the back chevron, visible whenever `isAnalyzing`
    /// is false, is the way back instead, the same as every other pushed screen in the flow per
    /// docs/UIUX.md). `.highPriorityGesture` on an ancestor beats a plain `.gesture` anywhere in
    /// its subtree, but when a descendant *also* uses `.highPriorityGesture`, SwiftUI resolves
    /// that tie in the descendant's favor — which is what lets `VideoScrubBar`'s own track keep
    /// winning locally for scrubbing, without this attachment needing to carve that view out.
    private var videoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard !isAnalyzing, browsingNeighbor == nil else { return }
                if value.translation.width > Self.swipeThreshold {
                    browse(previousVideo)
                } else if value.translation.width < -Self.swipeThreshold {
                    browse(nextVideo)
                }
            }
    }

    /// Stops the idle player before handing off to a neighbor — nothing would call
    /// `pause()` on it once this screen's identity changes underneath it, the same reason
    /// `idleControls`' "Start analysis" button pauses first.
    private func browse(_ navigate: (() -> Void)?) {
        guard let navigate else { return }
        player?.pause()
        navigate()
    }

    /// Mirrors `ResolutionBanner`'s two-state rendering of the same `Resolution` type — an
    /// iCloud download shows its real progress, a local/composition resolve shows an
    /// indeterminate spinner — so a swipe-triggered browse reports the same way the grid's
    /// own tile-tap resolution already does.
    private func browsingOverlay(_ resolution: VideoLibraryViewModel.Resolution) -> some View {
        VStack(spacing: 12) {
            if let progress = resolution.downloadProgress {
                Text("Downloading from iCloud…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                ProgressView(value: progress)
                    .tint(.white)
            } else {
                Text("Preparing video…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                ProgressView()
                    .tint(.white)
            }
            if let cancelBrowsing {
                Button("Cancel", role: .cancel, action: cancelBrowsing)
                    .tint(.white)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .allowsHitTesting(true)
        // `.overlay` content sits alongside `body`'s `Group`, not inside it, so `body`'s own
        // gesture attachment doesn't reach here — without this, a swipe on this overlay would
        // have no recognizer of its own and fall through to the page `TabView` beneath it. The
        // gesture's own `browsingNeighbor == nil` guard is what keeps it a no-op while this
        // overlay is up.
        .highPriorityGesture(videoSwipeGesture)
    }

    /// The video stage: the picked video fills the screen with no native playback
    /// chrome (`BareVideoPlayerView`) — Photos-app look, black background, no title, no
    /// caption. This backs both `.idle` (scrub bar + "Start analysis" button over the
    /// bottom) and `.processing` (progress overlay over the bottom instead) — the video
    /// stays on screen and paused behind the progress UI rather than the analysis
    /// replacing it with a separate page.
    private var videoStage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                BareVideoPlayerView(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            if isAnalyzing {
                Color.black.opacity(0.45).ignoresSafeArea()
                if let progress = currentProgress, let displaySize {
                    poseOverlay(keypoints: progress.keypoints, displaySize: displaySize)
                }
            }
        }
        // `body`'s single `.highPriorityGesture(videoSwipeGesture)` attachment (see its own doc
        // comment) covers this whole stage, video area and safe-area inset alike — nothing is
        // attached here directly.
        // `.safeAreaInset`, not `.overlay`: an overlay sizes its content at its own
        // ideal width and aligns it, so `PrimaryActionBar`'s full-width button has no
        // wider proposal to expand into and stays text-hugging. A safe-area inset
        // reserves real full-width space instead.
        .safeAreaInset(edge: .bottom) {
            if case .processing(let progress) = viewModel.state {
                processingOverlay(progress)
            } else {
                idleControls
            }
        }
    }

    /// The current frame's skeleton, positioned over the exact letterboxed rect
    /// `BareVideoPlayerView`'s `.resizeAspect` gravity draws the video into — not a
    /// full-bleed canvas, which would misalign against the video's own aspect-fit letterbox
    /// whenever the source isn't exactly screen-shaped. `AVMakeRect` computes that same
    /// letterbox math; `.ignoresSafeArea()` matches the `GeometryReader` proxy's frame to
    /// the player's, since the player itself ignores the safe area.
    private func poseOverlay(keypoints: [PoseKeypoint], displaySize: CGSize) -> some View {
        GeometryReader { proxy in
            let frame = AVMakeRect(aspectRatio: displaySize, insideRect: proxy.frame(in: .local))
            PoseOverlayView(keypoints: keypoints)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var idleControls: some View {
        VStack(spacing: 12) {
            if let player {
                // `VideoScrubBar`'s own track carries a `.highPriorityGesture` of its own
                // (needed there, for horizontal drags to scrub) — see its doc comment for why
                // that safely keeps priority here even though `body`'s swipe gesture is attached
                // as an ancestor of this whole bar.
                VideoScrubBar(player: player)
                    .padding(.horizontal)
            }
            // Pause the idle player before this state leaves the hierarchy:
            // nothing would call `pause()` on it afterwards, so its audio would
            // keep playing behind the progress UI and the clip list.
            PrimaryActionBar("Start analysis") {
                player?.pause()
                viewModel.start(video: video)
            }
        }
    }

    /// The progress panel drawn over the bottom of the still-visible, paused video —
    /// replaces `idleControls` in the same safe-area inset rather than replacing the
    /// video stage itself.
    private func processingOverlay(_ progress: ProcessingProgress) -> some View {
        VStack(spacing: 12) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .accessibilityLabel("Analysis progress")
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Analyzing video")
            }
            Text(progress.label)
                .font(.headline)
                .foregroundStyle(.white)
            Text("This runs fully on-device and can take a while for long videos.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private var emptyState: some View {
        StatusStateView(
            systemImage: "film",
            title: "No tricks found",
            message: "The whole video was analyzed but nothing moved like a trick. "
                + "Try a clip with bigger, faster movement."
        ) {
            Button("Back to Home") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
    }

    private func errorState(message: String) -> some View {
        StatusStateView(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't analyze this video",
            message: message
        ) {
            VStack(spacing: 12) {
                Button("Retry") { viewModel.retry(video: video) }
                    .buttonStyle(.borderedProminent)
                Button("Back to Home", role: .cancel) { dismiss() }
            }
            .padding(.top, 8)
        }
    }
}

#Preview {
    NavigationStack {
        ProcessingView(
            video: SelectedVideo(
                assetIdentifier: "preview",
                asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent.mov")),
                duration: 12
            ),
            autostart: false,
            destination: { result, _ in
                Text("\(result.clips.count) clips")
            }
        )
    }
    .preferredColorScheme(.dark)
}
