// AVFoundation predates Swift concurrency and isn't Sendable-audited, but its own
// threading contract already guarantees what these calls need: `AVCaptureSession`
// configuration is documented safe from any thread as long as it's bracketed by
// begin/commitConfiguration, which is exactly how `sessionQueue` uses it.
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A lens choice exposed to the UI as an "0.5x / 1x / 2x"-style pill. `zoomFactor` is the
/// *raw* `videoZoomFactor` value on the virtual device that activates this physical lens;
/// `label` is the display multiplier derived from it (see
/// `CameraCaptureViewModel.computeLensOptions(for:)`).
struct LensOption: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let zoomFactor: CGFloat
}

/// One resolution+frame-rate combination pulled from `AVCaptureDevice.formats`, plus the
/// `AVCaptureDevice.Format` needed to actually select it — the option list is built from
/// whatever the connected device reports rather than a fixed guess, since availability
/// differs per device and per lens.
struct CameraFormatOption: Identifiable, Equatable {
    let id: String
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let fps: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// `CameraFormatOption`s grouped by resolution, for a two-level "resolution -> fps" menu.
struct CameraFormatGroup: Identifiable {
    let id: String
    let label: String
    let options: [CameraFormatOption]
}

/// Backs the camera-recording screen: permission, session lifecycle, recording, and the
/// manual controls (lens/zoom, front/rear flip, resolution/fps, torch, exposure bias).
/// All `AVCaptureSession`/`AVCaptureDevice` mutation past the very first configuration —
/// input swaps, format changes, start/stop — happens on `sessionQueue`, never inline on
/// whatever thread called in, since those are blocking AVFoundation calls that would
/// otherwise stall the UI on every flip/format tap.
@MainActor
final class CameraCaptureViewModel: NSObject, ObservableObject {
    @Published private(set) var authorization: CameraAccessState = .notDetermined
    @Published private(set) var isRecording = false
    @Published private(set) var recordedFileURL: URL?
    @Published var errorMessage: String?

    @Published private(set) var hasCaptureDevice = false
    @Published private(set) var lensOptions: [LensOption] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isTorchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = 0...0
    @Published private(set) var availableFormats: [CameraFormatOption] = []
    @Published private(set) var currentFormatLabel = ""

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var isConfigured = false
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    /// Live-pinch baseline: the zoom factor the device was at when the current pinch
    /// gesture began, so each `onChanged` value (a cumulative magnification since
    /// gesture start) multiplies against a fixed base rather than compounding per frame.
    private var pinchBaseZoomFactor: CGFloat?
    private let sessionQueue = DispatchQueue(label: "com.hoiekim.turnip.camera.session")

    #if DEBUG
    /// Live pose inference alongside recording (docs/LIVE_POSE.md), a DEBUG-only prototype behind
    /// this flag until the on-device acceptance gate passes. On: a video data output sits on the
    /// session ahead of the movie output, and each finished recording is reviewed on the pose
    /// diagnostic screen before the file is handed on.
    @Published private(set) var isLivePoseEnabled = false
    /// False from the first enable until the model has loaded; a Record tap in that window is
    /// ignored rather than silently producing a take without live pose.
    @Published private(set) var isLivePoseReady = false
    /// The finished recording being reviewed; `livePoseReviewDismissed()` hands its file on.
    @Published var livePoseReview: LivePoseReview?
    /// `nonisolated` so the recording delegate, which AVFoundation calls off the main actor, can
    /// reach it; the tap is `Sendable` and does its own locking.
    nonisolated let livePoseTap = LivePoseFrameTap()
    /// Loaded once, on the first enable, and reused across recordings.
    private var poseModel: MoveNetThunderModel?
    /// The consumer of the last stopped recording while it drains. A new recording cancels it.
    private var drainingLivePose: LivePoseRecording?
    private var pendingLivePoseFileURL: URL?
    #endif

    /// Candidate frame rates to probe each format against, rather than only reading off
    /// each range's `maxFrameRate` — a format whose range is (say) 1...30 would otherwise
    /// never offer 24fps even though it's a perfectly valid rate within that range.
    private nonisolated static let candidateFrameRates = [24, 25, 30, 50, 60, 120, 240]

    var formatGroups: [CameraFormatGroup] {
        let grouped = Dictionary(grouping: availableFormats) { "\($0.width)x\($0.height)" }
        return grouped.keys
            .sorted { lhs, rhs in
                let leftArea = (grouped[lhs]?.first).map { Int($0.width) * Int($0.height) } ?? 0
                let rightArea = (grouped[rhs]?.first).map { Int($0.width) * Int($0.height) } ?? 0
                return leftArea > rightArea
            }
            .compactMap { key -> CameraFormatGroup? in
                guard let options = grouped[key]?.sorted(by: { $0.fps < $1.fps }),
                      let first = options.first else { return nil }
                return CameraFormatGroup(id: key, label: "\(first.width) \u{00D7} \(first.height)", options: options)
            }
    }

    /// The lens pill that matches the current zoom factor — the highest-activation lens
    /// at or below `zoomFactor` is the one currently in effect.
    var activeLensZoomFactor: CGFloat {
        lensOptions.filter { $0.zoomFactor <= zoomFactor }.map(\.zoomFactor).max()
            ?? lensOptions.first?.zoomFactor
            ?? 1
    }

    /// Requests camera + microphone access on first launch, then starts the session.
    /// Safe to call again — a second call after a prompt just resumes the session.
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
        if isConfigured {
            await resumeRunningSession()
            return
        }
        isConfigured = true
        let (device, input) = await configureSessionAndStart()
        videoDevice = device
        videoInput = input
        refreshDeviceCapabilities()
    }

    /// Also clears `isTorchOn`: torch physically turns off once the session stops
    /// running, so the published state would otherwise claim it's still on.
    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
        isTorchOn = false
        #if DEBUG
        cancelLivePose()
        #endif
    }

    /// With live pose on, a Record tap is ignored while the model is still loading and while the
    /// previous take's consumer is still draining: both last seconds, and a take started under
    /// either would either miss live pose silently or leave the finished file with nowhere to go.
    func toggleRecording() {
        if isRecording {
            movieOutput.stopRecording()
        } else {
            #if DEBUG
            guard drainingLivePose == nil, !isLivePoseEnabled || isLivePoseReady else { return }
            #endif
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("turnip-recording-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            recordedFileURL = nil
            #if DEBUG
            armLivePose()
            #endif
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
        }
    }

    // MARK: - Lens / zoom

    func selectLens(_ option: LensOption) {
        guard !isRecording, let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: option.zoomFactor, withRate: 8)
            device.unlockForConfiguration()
            zoomFactor = option.zoomFactor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `magnification` is `MagnificationGesture`'s cumulative value since the gesture
    /// began (not a per-frame delta), so the base zoom is captured once on first call
    /// and every subsequent call multiplies against that same base. Sets
    /// `videoZoomFactor` directly rather than `ramp`ing, for immediate 1:1 pinch feedback.
    func pinchChanged(byMagnification magnification: CGFloat) {
        guard let device = videoDevice else { return }
        let base = pinchBaseZoomFactor ?? device.videoZoomFactor
        pinchBaseZoomFactor = base
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10)
        let target = min(max(base * magnification, minZoom), maxZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            zoomFactor = target
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pinchEnded() {
        pinchBaseZoomFactor = nil
    }

    // MARK: - Torch

    func toggleTorch() {
        applyTorch(!isTorchOn)
    }

    /// Torch state lives on the `AVCaptureDevice` instance itself, not the session, so it
    /// doesn't carry over when `switchCamera()` installs a different device — callers
    /// re-apply the desired state explicitly after a swap.
    private func applyTorch(_ isOn: Bool) {
        guard let device = videoDevice, device.hasTorch, device.isTorchAvailable else {
            isTorchOn = false
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = isOn ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = isOn
        } catch {
            isTorchOn = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Exposure

    func setExposureBias(_ value: Float) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(value) { _ in }
            device.unlockForConfiguration()
            exposureBias = value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exposure bias doesn't carry over meaningfully across a device swap (front/rear or
    /// a different physical lens), so the newly installed device is put back to neutral
    /// on both the device and the published UI state, rather than just the UI resetting
    /// while the hardware keeps whatever bias the old device was holding.
    private func resetExposureBias(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(0) { _ in }
            device.unlockForConfiguration()
        } catch {
            errorMessage = error.localizedDescription
        }
        exposureBias = 0
    }

    // MARK: - Resolution / frame rate

    /// Sets `activeFormat` before the frame duration, since assigning `activeFormat`
    /// resets any frame-duration override back to the format's own default — the reverse
    /// order would silently drop the chosen frame rate. Assigning `activeFormat` can also
    /// reset the device's zoom back to 1.0, so the zoom factor in effect just before the
    /// change is restored (clamped to the new format's available range) rather than left
    /// to whatever the format reset it to. Runs on `sessionQueue`, and re-checks
    /// `isRecording` there since the caller's own guard can go stale in the gap before
    /// this closure runs.
    func applyFormat(_ option: CameraFormatOption) {
        guard !isRecording, let device = videoDevice else { return }
        let format = option.format
        let fps = option.fps
        let movieOutput = self.movieOutput
        sessionQueue.async {
            guard !movieOutput.isRecording else { return }
            do {
                try device.lockForConfiguration()
                let previousZoom = device.videoZoomFactor
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                let restoredZoom = min(
                    max(previousZoom, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = restoredZoom
                device.unlockForConfiguration()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    currentFormatLabel = "\(option.width)\u{00D7}\(option.height) \u{00B7} \(fps)fps"
                    zoomFactor = restoredZoom
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Front / rear switch

    func switchCamera() {
        guard !isRecording, let currentDevice = videoDevice else { return }
        let newPosition: AVCaptureDevice.Position = currentDevice.position == .back ? .front : .back
        guard let newDevice = Self.bestDevice(for: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        let wasTorchOn = isTorchOn
        let session = self.session
        let oldInput = videoInput
        let movieOutput = self.movieOutput
        sessionQueue.async {
            guard !movieOutput.isRecording else { return }
            session.beginConfiguration()
            if let oldInput {
                session.removeInput(oldInput)
            }
            let added = session.canAddInput(newInput)
            if added {
                session.addInput(newInput)
                // Every newly installed device needs the same seeding the very first
                // device got in `configureSessionAndStart()` — `.inputPriority` has no
                // built-in default, so without this a flip could land on a 4:3
                // photo-oriented format or the wrong lens's full-wide zoom.
                Self.seedDefaultFormat(on: newDevice)
                Self.seedDefaultZoom(on: newDevice)
            } else if let oldInput {
                session.addInput(oldInput)
            }
            session.commitConfiguration()
            guard added else { return }
            Self.applyMirroringPolicy(to: movieOutput)
            Task { @MainActor [weak self] in
                guard let self else { return }
                videoDevice = newDevice
                videoInput = newInput
                refreshDeviceCapabilities()
                applyTorch(wasTorchOn)
                resetExposureBias(on: newDevice)
            }
        }
    }

    // MARK: - Session configuration

    private func resumeRunningSession() async {
        let session = self.session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    /// One-time session setup: adds the back camera + microphone inputs and the movie
    /// output, then starts the session — all on `sessionQueue`, since `AVCaptureSession`
    /// configuration and `startRunning()` are the same kind of blocking call the rest of
    /// this class avoids running on the caller's thread. Uses `.inputPriority`, not
    /// `.high`: a session preset actively manages the device's format on its own and
    /// silently overrides a manually chosen `activeFormat`/frame-duration (the
    /// resolution/fps menu) if left in a preset mode.
    private func configureSessionAndStart() async -> (AVCaptureDevice?, AVCaptureDeviceInput?) {
        let session = self.session
        let movieOutput = self.movieOutput
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .inputPriority
                var resultDevice: AVCaptureDevice?
                var resultInput: AVCaptureDeviceInput?
                if let device = Self.bestDevice(for: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                    Self.seedDefaultFormat(on: device)
                    Self.seedDefaultZoom(on: device)
                    resultDevice = device
                    resultInput = input
                }
                if let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
                if session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                }
                session.commitConfiguration()
                Self.applyMirroringPolicy(to: movieOutput)
                session.startRunning()
                continuation.resume(returning: (resultDevice, resultInput))
            }
        }
    }

    private func refreshDeviceCapabilities() {
        guard let device = videoDevice else {
            hasCaptureDevice = false
            lensOptions = []
            zoomFactor = 1
            isTorchAvailable = false
            isTorchOn = false
            exposureBias = 0
            exposureBiasRange = 0...0
            availableFormats = []
            currentFormatLabel = ""
            return
        }
        hasCaptureDevice = true
        lensOptions = Self.computeLensOptions(for: device)
        zoomFactor = device.videoZoomFactor
        isTorchAvailable = device.hasTorch && device.isTorchAvailable
        exposureBias = 0
        exposureBiasRange = device.minExposureTargetBias...device.maxExposureTargetBias
        availableFormats = Self.computeFormatOptions(for: device)
        currentFormatLabel = Self.label(forActiveFormatOf: device)
    }

    /// Prefers the widest available virtual (multi-lens) device, falling back to
    /// progressively narrower virtual devices and finally the single physical wide lens
    /// (no lens-switch capability at all).
    private nonisolated static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    /// Preview mirrors the front camera automatically (comfortable "selfie" framing while
    /// shooting), but this app never mirrors the saved file, so exported clips read with
    /// correct orientation — readable text, correct left/right — regardless of which
    /// camera shot them. `isVideoMirroringSupported` is expected true for a camera ->
    /// movie-output connection, but guarded anyway since setting `isVideoMirrored` on an
    /// unsupported connection raises rather than failing silently. Applied to every video
    /// output on the session so frames analyzed live agree with the file left-to-right.
    private nonisolated static func applyMirroringPolicy(to output: AVCaptureOutput) {
        guard let connection = output.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        guard connection.isVideoMirroringSupported else { return }
        connection.isVideoMirrored = false
    }

    /// Picks a plain 1920x1080@30 format so the first recording after launch has a
    /// predictable shape. Needed only because of `.inputPriority`: unlike a session
    /// preset, it has no built-in default, so a fresh device could otherwise hand the
    /// very first recording whatever format `activeFormat` happens to already be set to
    /// (on some devices, a 4:3 photo-oriented one). Best-effort — if no such format
    /// exists, recording proceeds with the device's own default.
    private nonisolated static func seedDefaultFormat(on device: AVCaptureDevice) {
        guard let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {}
    }

    /// A fresh virtual (multi-lens) device's raw `videoZoomFactor` starts at 1.0, which
    /// is its *widest* lens (ultra-wide, when present) — without this, the camera would
    /// silently open on 0.5x instead of the expected 1x. Sets the zoom to whatever raw
    /// factor `computeLensOptions` says activates the normal wide lens.
    private nonisolated static func seedDefaultZoom(on device: AVCaptureDevice) {
        let target = defaultZoomFactor(for: device)
        guard target != device.videoZoomFactor else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        } catch {}
    }

    private nonisolated static func defaultZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        computeLensOptions(for: device).first(where: { $0.label == "1x" })?.zoomFactor ?? 1
    }

    /// Derives displayed lens multipliers ("0.5x/1x/2x") from
    /// `virtualDeviceSwitchOverVideoZoomFactors`. A virtual device's raw `videoZoomFactor`
    /// starts at 1.0 for its widest constituent lens and crosses each switch-over factor
    /// to activate the next lens in `constituentDevices`, so lens *i*'s raw activation
    /// factor is 1.0 for the first lens and `switchOverVideoZoomFactors[i - 1]` after
    /// that. The displayed "1x" always means the normal wide lens, whichever raw factor
    /// that lens activates at (1.0 if it's the widest constituent, or the first
    /// switch-over factor if an ultra-wide lens comes before it) — every other lens's
    /// label is its own raw activation factor divided by that baseline.
    private nonisolated static func computeLensOptions(for device: AVCaptureDevice) -> [LensOption] {
        guard device.isVirtualDevice else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let constituents = device.constituentDevices
        guard !constituents.isEmpty else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var rawFactors: [CGFloat] = [1]
        rawFactors.append(contentsOf: switchOvers)
        let count = min(rawFactors.count, constituents.count)
        guard count > 0 else {
            return [LensOption(label: "1x", zoomFactor: 1)]
        }
        let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) ?? 0
        let baseline = wideIndex < rawFactors.count ? rawFactors[wideIndex] : 1
        return (0..<count).map { index in
            let raw = rawFactors[index]
            let multiplier = baseline > 0 ? raw / baseline : raw
            return LensOption(label: formatMultiplier(multiplier), zoomFactor: raw)
        }
    }

    private nonisolated static func formatMultiplier(_ value: CGFloat) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))x"
        }
        return String(format: "%.1fx", value)
    }

    /// Built from `device.formats` rather than a fixed list — a virtual multi-lens
    /// device and a single physical lens can expose very different resolution/fps
    /// combinations, so hardcoding "720p/1080p/4K x 24/30/60" would silently claim
    /// options the connected device doesn't actually support (or omit ones it does).
    /// Restricted to plain 16:9 video-range formats: `device.formats` also lists 4:3
    /// photo-oriented formats and multiple pixel-format variants (HDR, binned, etc.) that
    /// would otherwise flood this menu with options this app has no use for.
    private nonisolated static func computeFormatOptions(for device: AVCaptureDevice) -> [CameraFormatOption] {
        var seenIDs = Set<String>()
        var options: [CameraFormatOption] = []
        for format in device.formats {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { continue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0,
                  dimensions.width * 9 == dimensions.height * 16 else { continue }
            for fps in candidateFrameRates {
                let supported = format.videoSupportedFrameRateRanges.contains { range in
                    Double(fps) >= range.minFrameRate - 0.01 && Double(fps) <= range.maxFrameRate + 0.01
                }
                guard supported else { continue }
                let id = "\(dimensions.width)x\(dimensions.height)@\(fps)"
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                options.append(CameraFormatOption(
                    id: id, format: format, width: dimensions.width, height: dimensions.height, fps: fps))
            }
        }
        return options
    }

    private nonisolated static func label(forActiveFormatOf device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard let frameRate = activeFrameRate(of: device) else {
            return "\(dimensions.width)\u{00D7}\(dimensions.height)"
        }
        return "\(dimensions.width)\u{00D7}\(dimensions.height) \u{00B7} \(Int(frameRate.rounded()))fps"
    }

    /// The frame rate the device is capturing at, from its active frame duration; nil when the
    /// device reports no duration.
    private nonisolated static func activeFrameRate(of device: AVCaptureDevice) -> Double? {
        let duration = device.activeVideoMinFrameDuration
        guard duration.value > 0 else { return nil }
        return Double(duration.timescale) / Double(duration.value)
    }
}

extension CameraCaptureViewModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        #if DEBUG
        livePoseTap.recordingDidStart()
        #endif
    }

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
                #if DEBUG
                livePoseTap.cancel()
                #endif
                return
            }
            #if DEBUG
            if reviewLivePoseIfNeeded(for: outputFileURL) {
                return
            }
            #endif
            recordedFileURL = outputFileURL
        }
    }
}

#if DEBUG
// MARK: - Live pose (prototype)

extension CameraCaptureViewModel {
    /// Attaches or detaches the live-pose data output. The movie output is removed and re-added
    /// around it so the data output always sits ahead of the movie output on the session and the
    /// movie output's connection is formed the same way whether or not the flag is on — with the
    /// flag off, the session is exactly what a release build runs. Only while not recording.
    func toggleLivePose() {
        guard !isRecording else { return }
        let enable = !isLivePoseEnabled
        isLivePoseEnabled = enable
        if enable, poseModel == nil {
            loadPoseModel()
        }
        let session = self.session
        let movieOutput = self.movieOutput
        let dataOutput = livePoseTap.output
        sessionQueue.async {
            guard !movieOutput.isRecording else { return }
            session.beginConfiguration()
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            if enable {
                if session.canAddOutput(dataOutput) {
                    session.addOutput(dataOutput)
                }
            } else if session.outputs.contains(dataOutput) {
                session.removeOutput(dataOutput)
            }
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            session.commitConfiguration()
            Self.applyMirroringPolicy(to: movieOutput)
            Self.applyMirroringPolicy(to: dataOutput)
        }
    }

    /// The review sheet closed: hand the recording on exactly as a recording without live pose
    /// would have been.
    func livePoseReviewDismissed() {
        guard let url = pendingLivePoseFileURL else { return }
        pendingLivePoseFileURL = nil
        recordedFileURL = url
    }

    /// A load failure (the `.tflite` is not bundled) turns the flag back off, so the screen does
    /// not sit waiting for a model that will never arrive.
    private func loadPoseModel() {
        Task { [weak self] in
            do {
                let model = try await MoveNetThunderModel.load()
                self?.poseModel = model
                self?.isLivePoseReady = true
            } catch {
                self?.errorMessage = (error as? PoseError)?.errorDescription ?? error.localizedDescription
                if self?.isLivePoseEnabled == true {
                    self?.toggleLivePose()
                }
            }
        }
    }

    /// Record was tapped: give this recording its own consumer and arm the tap. The consumer is
    /// never shared between recordings.
    private func armLivePose() {
        guard isLivePoseEnabled, let poseModel, let device = videoDevice,
              let dataConnection = livePoseTap.output.connection(with: .video),
              let movieConnection = movieOutput.connection(with: .video) else { return }
        let rotation = LivePoseKeypointRotation.relativeDegrees(
            producer: LivePoseFrameTap.rotationDegrees(of: dataConnection),
            consumer: LivePoseFrameTap.rotationDegrees(of: movieConnection))
        let recording = LivePoseRecording(
            inference: { try await poseModel.runInference(on: $0) },
            channel: LivePoseSampleChannel(),
            rotationDegrees: rotation)
        livePoseTap.arm(
            recording: recording,
            preparer: poseModel.inputPreparer,
            frameRate: Self.activeFrameRate(of: device) ?? 30)
    }

    /// The movie output finished writing `url`. When a live-pose recording was running, waits for
    /// its consumer to drain and then presents the review instead of handing the file on; returns
    /// false when there was none and the caller should hand the file on itself. A drain that was
    /// cancelled (the camera was left) has no review to show, so the file is handed on directly —
    /// the recording itself finished fine.
    private func reviewLivePoseIfNeeded(for url: URL) -> Bool {
        guard let recording = livePoseTap.endRecording() else { return false }
        drainingLivePose = recording
        Task { [weak self] in
            let outcome = await recording.outcome()
            guard let self else { return }
            if drainingLivePose === recording {
                drainingLivePose = nil
            }
            if outcome.metrics.wasCancelled {
                recordedFileURL = url
            } else {
                pendingLivePoseFileURL = url
                livePoseReview = LivePoseReview(fileURL: url, outcome: outcome)
            }
        }
        return true
    }

    private func cancelLivePose() {
        livePoseTap.cancel()
        drainingLivePose?.cancel(producer: nil)
        drainingLivePose = nil
    }
}
#endif
