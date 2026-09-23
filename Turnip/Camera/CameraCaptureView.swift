import AVFoundation
import SwiftUI

/// The camera-recording screen, one of the two pages `RootTabView` swipes between:
/// full-screen preview, a cancel chevron, manual controls (lens/zoom, front/rear flip,
/// resolution/fps, torch, exposure bias), and one record button. On a successful
/// recording, `onFinished` hands the caller the temp file so it can save it to Photos and
/// feed the resulting `PHAsset` into the existing picked-video pipeline — this screen
/// knows nothing about Photos or navigation. `onCancel` backs out to the gallery tab; a
/// no-op default since not every caller (e.g. a preview) needs one.
struct CameraCaptureView: View {
    let onFinished: (URL) -> Void
    var onCancel: () -> Void = {}

    @StateObject private var viewModel = CameraCaptureViewModel()
    @State private var showExposureSlider = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.authorization {
            case .authorized:
                CameraPreviewView(session: viewModel.session)
                    .ignoresSafeArea()
                    .overlay {
                        // A transparent gesture catcher, not `.gesture` directly on the
                        // representable: the hosted `UIView` would otherwise hit-test the
                        // touch first. Sits below the button overlays added later in this
                        // modifier chain, so it never intercepts their taps.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(pinchZoomGesture)
                    }
            case .denied(let restricted):
                CameraAccessDeniedView(restricted: restricted)
            case .notDetermined:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) { cancelButton }
        .overlay(alignment: .topTrailing) {
            if viewModel.authorization == .authorized {
                topRightControls
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.authorization == .authorized {
                bottomControls
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.recordedFileURL) { url in
            guard let url else { return }
            onFinished(url)
        }
        .alert("Couldn't record video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        #if DEBUG
        .sheet(item: $viewModel.livePoseReview, onDismiss: viewModel.livePoseReviewDismissed) { review in
            NavigationStack {
                PoseDiagnosticView(
                    video: SelectedVideo(
                        assetIdentifier: "live-pose-review",
                        asset: AVURLAsset(url: review.fileURL),
                        duration: review.outcome.metrics.recordingDuration),
                    liveOutcome: review.outcome)
            }
        }
        #endif
    }

    private var cancelButton: some View {
        ScrimIconButton(systemImage: "xmark", accessibilityLabel: "Cancel", action: onCancel)
            .padding()
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if showExposureSlider {
                exposureSlider
            }
            if viewModel.lensOptions.count > 1 {
                lensPillRow
            }
            recordButton
        }
    }

    private var recordButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: viewModel.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(
                        width: viewModel.isRecording ? 28 : 60,
                        height: viewModel.isRecording ? 28 : 60)
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.isRecording)
        }
        .padding(.bottom, 24)
        .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Lens / zoom

    private var lensPillRow: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.lensOptions) { option in
                Button {
                    viewModel.selectLens(option)
                } label: {
                    Text(option.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                option.zoomFactor == viewModel.activeLensZoomFactor
                                    ? Color.yellow.opacity(0.9)
                                    : Color.black.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(viewModel.isRecording ? 0.4 : 1)
        .disabled(viewModel.isRecording)
        .accessibilityElement(children: .contain)
    }

    private var pinchZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in viewModel.pinchChanged(byMagnification: value) }
            .onEnded { _ in viewModel.pinchEnded() }
    }

    // MARK: - Top-right controls

    private var topRightControls: some View {
        HStack(spacing: 12) {
            #if DEBUG
            if viewModel.hasCaptureDevice {
                livePoseButton
            }
            #endif
            if viewModel.exposureBiasRange.lowerBound < viewModel.exposureBiasRange.upperBound {
                exposureToggleButton
            }
            if viewModel.isTorchAvailable {
                flashButton
            }
            if !viewModel.formatGroups.isEmpty {
                formatMenu
            }
            if viewModel.hasCaptureDevice {
                flipButton
            }
        }
        .padding()
    }

    private var exposureToggleButton: some View {
        ScrimIconButton(
            systemImage: showExposureSlider ? "sun.max.fill" : "sun.max",
            accessibilityLabel: "Exposure",
            action: { showExposureSlider.toggle() })
    }

    private var flashButton: some View {
        ScrimIconButton(
            systemImage: viewModel.isTorchOn ? "bolt.fill" : "bolt.slash.fill",
            accessibilityLabel: viewModel.isTorchOn ? "Turn off flash" : "Turn on flash",
            action: viewModel.toggleTorch)
    }

    #if DEBUG
    /// The prototype flag from docs/LIVE_POSE.md. Filled glyph while on; dimmed while the model
    /// is still loading, when Record is ignored.
    private var livePoseButton: some View {
        let loading = viewModel.isLivePoseEnabled && !viewModel.isLivePoseReady
        return ScrimIconButton(
            systemImage: viewModel.isLivePoseEnabled ? "figure.run.circle.fill" : "figure.run.circle",
            accessibilityLabel: viewModel.isLivePoseEnabled
                ? (loading ? "Live pose loading" : "Turn off live pose")
                : "Turn on live pose",
            action: viewModel.toggleLivePose)
            .opacity(viewModel.isRecording || loading ? 0.4 : 1)
            .disabled(viewModel.isRecording)
    }
    #endif

    private var flipButton: some View {
        ScrimIconButton(
            systemImage: "arrow.triangle.2.circlepath.camera",
            accessibilityLabel: "Switch camera",
            action: viewModel.switchCamera)
            .opacity(viewModel.isRecording ? 0.4 : 1)
            .disabled(viewModel.isRecording)
    }

    /// Not `ScrimIconButton` here: `Menu`'s `label` closure needs a bare glyph, and
    /// nesting `ScrimIconButton`'s own `Button` inside it would fight `Menu` for the tap.
    /// Mirrors `ScrimIconButton`'s look so it reads as the same control family.
    private var formatMenu: some View {
        Menu {
            Text(viewModel.currentFormatLabel)
            Divider()
            ForEach(viewModel.formatGroups) { group in
                Menu(group.label) {
                    ForEach(group.options) { option in
                        Button("\(option.fps) fps") {
                            viewModel.applyFormat(option)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
        .opacity(viewModel.isRecording ? 0.4 : 1)
        .disabled(viewModel.isRecording)
        .accessibilityLabel("Resolution and frame rate")
    }

    // MARK: - Exposure

    private var exposureSlider: some View {
        Slider(
            value: Binding(
                get: { viewModel.exposureBias },
                set: { viewModel.setExposureBias($0) }),
            in: viewModel.exposureBiasRange
        )
        .tint(.yellow)
        .padding(.horizontal, 40)
        .accessibilityLabel("Exposure bias")
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct CameraAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        StatusStateView(
            systemImage: "camera.fill",
            title: "Turnip needs camera access",
            message: restricted
                ? "Camera access is restricted on this device."
                : "Allow camera and microphone access in Settings to record a trick."
        ) {
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
    }
}
