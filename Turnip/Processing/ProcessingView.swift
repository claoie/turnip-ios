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
        destination: @escaping (ProcessingResult, @escaping () -> Void) -> Destination
    ) {
        self.video = video
        self.autostart = autostart
        self.popToRoot = popToRoot
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .processing:
                videoStage
            case .empty:
                emptyState
            case .failed(let message):
                errorState(message: message)
            case .succeeded:
                // Covered by the pushed destination; only visible when navigating back here.
                Text("Analysis complete.")
                    .foregroundStyle(.secondary)
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
