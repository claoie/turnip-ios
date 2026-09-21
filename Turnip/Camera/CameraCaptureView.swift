import SwiftUI

/// The camera-recording screen, one of the two pages `RootTabView` swipes between. Minimal
/// v1 scope: full-screen back-camera preview, a cancel chevron, and one record button. On a
/// successful recording, `onFinished` hands the caller the temp file so it can save it to
/// Photos and feed the resulting `PHAsset` into the existing picked-video pipeline — this
/// screen knows nothing about Photos or navigation. `onCancel` backs out to the gallery tab;
/// a no-op default since not every caller (e.g. a preview) needs one.
struct CameraCaptureView: View {
    let onFinished: (URL) -> Void
    var onCancel: () -> Void = {}

    @StateObject private var viewModel = CameraCaptureViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.authorization {
            case .authorized:
                CameraPreviewView(session: viewModel.session)
                    .ignoresSafeArea()
            case .denied(let restricted):
                CameraAccessDeniedView(restricted: restricted)
            case .notDetermined:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) { cancelButton }
        .safeAreaInset(edge: .bottom) {
            if viewModel.authorization == .authorized {
                recordButton
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
    }

    private var cancelButton: some View {
        ScrimIconButton(systemImage: "xmark", accessibilityLabel: "Cancel", action: onCancel)
            .padding()
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
