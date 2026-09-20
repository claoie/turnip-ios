import SwiftUI

/// The camera-recording screen, reached from Home's "swipe up to take a video" affordance.
/// Minimal v1 scope: full-screen back-camera preview, a cancel chevron, and one record
/// button. On a successful recording, `onFinished` hands the caller the temp file so it can
/// save it to Photos and feed the resulting `PHAsset` into the existing picked-video
/// pipeline — this screen knows nothing about Photos or navigation.
struct CameraCaptureView: View {
    let onFinished: (URL) -> Void

    @StateObject private var viewModel = CameraCaptureViewModel()
    @Environment(\.dismiss) private var dismiss

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
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
        .padding()
        .accessibilityLabel("Cancel")
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
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Turnip needs camera access")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(
                restricted
                    ? "Camera access is restricted on this device."
                    : "Allow camera and microphone access in Settings to record a trick."
            )
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding(32)
    }
}
