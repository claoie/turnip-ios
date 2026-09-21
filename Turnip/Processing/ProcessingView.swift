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
            if autostart {
                viewModel.start(video: video)
            }
        }
        .onDisappear {
            viewModel.cancel()
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
