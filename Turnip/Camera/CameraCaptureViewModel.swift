import AVFoundation
import Foundation

/// Backs the camera-recording screen: permission, session lifecycle, and one
/// start/stop recording toggle. v1 scope only — back camera, no flip/flash/zoom.
@MainActor
final class CameraCaptureViewModel: NSObject, ObservableObject {
    @Published private(set) var authorization: CameraAccessState = .notDetermined
    @Published private(set) var isRecording = false
    @Published private(set) var recordedFileURL: URL?
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var isConfigured = false

    /// Requests camera + microphone access on first launch, then starts the session.
    /// Safe to call again — a second call after a prompt just (re)starts the session.
    func start() async {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        authorization = CameraAccessState(video: videoStatus, audio: audioStatus)
        if authorization == .notDetermined {
            let grantedVideo = await AVCaptureDevice.requestAccess(for: .video)
            let grantedAudio = await AVCaptureDevice.requestAccess(for: .audio)
            authorization = CameraAccessState(
                video: grantedVideo ? .authorized : .denied,
                audio: grantedAudio ? .authorized : .denied)
        }
        guard authorization == .authorized else { return }
        configureSessionIfNeeded()
        // A brief main-thread block on `startRunning()` is accepted for this v1 scope
        // rather than adding an actor/queue hop for a call that only runs once per screen.
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func toggleRecording() {
        if isRecording {
            movieOutput.stopRecording()
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("turnip-recording-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            recordedFileURL = nil
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
           session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
    }
}

extension CameraCaptureViewModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            isRecording = false
            if let error {
                errorMessage = error.localizedDescription
                return
            }
            recordedFileURL = outputFileURL
        }
    }
}
