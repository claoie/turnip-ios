# Live pose inference during recording

*Rev 1 · 2026-09-22 · Draft for review.*

*Companion to [`DESIGN.md`](DESIGN.md). This doc covers one question: can the pose pass start when recording starts, instead of after the file is written? Pipeline shape, budgets and model choice stay as recorded in `DESIGN.md`.*

## Decision

**Go, gated on one on-device test.** Add an `AVCaptureVideoDataOutput` alongside the existing `AVCaptureMovieFileOutput`, run the existing 10 samples/sec stride on the live frames, and let inference lag behind the recording and finish after it. Prototype in the DEBUG-only pose diagnostic screen. Ship only when the gate in "Acceptance gate" passes on the oldest supported device at 240 fps.

The recorder itself does not change. If the gate fails on the recording side, the fallback is the `AVCaptureVideoDataOutput` + `AVAssetWriter` rewrite described under "Alternatives", not a weaker version of this design.

## Problem

Today the pose pass is strictly post-hoc. `VideoFrameSampler` decodes the finished `.mov` with `AVAssetReader`, keeps every `round(fps / 10)`th frame, and hands each one to `MoveNetThunderModel`. For a 240 fps slo-mo take this means a full HEVC decode of the file after the user taps Stop, before any clip boundaries exist. The user waits for work that could have been done while they were still filming, on frames the ISP had already produced.

The goal is to have inference finish seconds after Stop rather than after a second decode. Deadlines are explicitly relaxed: inference is allowed to lag behind the recording and complete after it. What is not relaxed is the recording itself, which must stay drop-free.

## What is already true

These facts shape the design more than any external reference.

- **Recording** is `AVCaptureMovieFileOutput` only. There is no `AVCaptureVideoDataOutput` anywhere in the app. The session runs `sessionPreset = .inputPriority`, formats are filtered to `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, and frame rates offered go up to 240.
- **Inference** is TensorFlow Lite on the CPU: `Interpreter(modelPath:)` with no options, no delegate, default thread count. The video encoder is hardware. So the two workloads share the CPU with the capture session's own CPU work; they do not fight over the GPU or Neural Engine.
- **Preprocessing** is a Core Image letterbox rendered into a 32BGRA target, then an RGB repack into the 256×256×3 uint8 tensor. The 32BGRA guard is on the rendered target, not the source, so a 420v source buffer is fine.
- **Sampling** is ~10 frames/sec of footage regardless of source fps (stride 3 at 30 fps, 24 at 240 fps). Inference is "tens of ms per frame" against a 100 ms per-sample budget.
- **Results** are appended to a per-frame array in timestamp order. `nearestResult` binary-searches by timestamp and depends on that order. `PoseDiagnosticSummary` does not care about order.
- **Minimum iOS is 16.0.** This matters: before iOS 16, a movie file output and a video data output could not both be active on one session. Apple's `AVCaptureVideoDataOutput` documentation states that for apps linking against iOS 16 or later the restriction no longer exists.
- **No thermal handling** exists anywhere. `ProcessInfo.thermalState` is unused.
- The model is rebuilt via `load()` on every diagnostic run.

## Prior art

- **Apple's live-pose pattern** (WWDC20 "Detect Body and Hand Pose with Vision", the Action & Vision sample): `AVCaptureVideoDataOutput` on a dedicated serial queue, `alwaysDiscardsLateVideoFrames = true`, inference per delegate callback, frames dropped rather than queued when inference falls behind.
- **Recording plus ML before iOS 16**: because both outputs could not be active, ML camera apps fed a single `AVCaptureVideoDataOutput` stream to both an `AVAssetWriter` and the model. One frame stream, free timestamp alignment, but the app owns encoding, audio muxing, orientation and slo-mo metadata.
- **Recording plus ML on iOS 16+**: both outputs on one session. One format-dependent failure has been reported (ProRes422), which is why the gate below is specific about 420v at 240 fps rather than trusting the general statement.
- **Production practice**: measure inference time and adapt the sample rate instead of assuming a fixed budget; observe `ProcessInfo.thermalState` and back off at `.serious`, stop at `.critical`.

## The constraint that shapes everything

"Start now, finish later" cannot mean "queue raw frames, drain later." `AVCaptureVideoDataOutput` hands the delegate `CMSampleBuffer`s from a small fixed pool. Retain them past the callback and the output stalls or drops. So the only viable shape is to reduce each kept frame to its model input tensor synchronously, inside the callback, and queue the tensor.

The tensor is 256 × 256 × 3 bytes ≈ 196 KB. At 10 samples/sec that is ≈ 118 MB per minute if nothing drains, so the queue is bounded and the bound is a safety valve, not steady state. With inference in the tens of milliseconds and a 100 ms budget the queue should sit near empty; it only grows under thermal throttling or CPU contention.

## Design

### Capture side

1. Add an `AVCaptureVideoDataOutput` to the session next to `movieOutput`, in the same `beginConfiguration` block that builds the session today. Add it before the movie output so the movie output's connection settings are unaffected.
2. Leave `videoSettings` nil. The device format is 420v. Forcing 32BGRA to match the file sampler's contract would make the ISP convert all 240 frames/sec for the 10 that are kept. `CIImage(cvPixelBuffer:)` accepts 420v.
3. `alwaysDiscardsLateVideoFrames = true`. A dedicated serial queue with `.userInitiated` QoS, separate from `sessionQueue`. Session mutations and frame delivery must not block each other.
4. In `captureOutput(_:didOutput:from:)`, apply the same stride as the file path: keep frame `n` when `n % round(fps / 10) == 0`, computed from the active format's frame rate at record start. Non-kept frames return immediately. At 240 fps this callback fires 240 times a second, so the non-kept path is an increment and a return.
5. For kept frames: read the presentation timestamp, run the letterbox to the 256×256 tensor, push `(timestamp, tensor)` to the per-recording queue, return. Never retain the sample buffer or the pixel buffer.
6. Frames arrive only while the movie output is recording. The data output delivers whenever the session runs; gate on the recording state so preview-only time costs nothing.

### Inference side

1. `MoveNetThunderModel` is loaded once, when the camera screen appears, and reused across recordings. Today it is loaded per diagnostic run.
2. The letterbox and RGB repack move out of the model actor's async path into a synchronous function callable from the capture queue. The model actor then takes a tensor, not a pixel buffer. The file-based path calls the same function from `VideoFrameSampler`'s handler, so there is one preprocess implementation.
3. A per-recording queue, bounded to a few seconds of samples (30 entries ≈ 6 MB is a reasonable first bound). Drop-oldest on overflow, and count drops. The model actor drains it and appends results in dequeue order, which is timestamp order because the queue is FIFO and the capture callback is serial.
4. The queue is created on record start and owned by the recording, not the screen. It is cancelled on a second Record tap, on leaving the camera tab, and on session teardown. A consumer that outlives the recording must be the one for that recording, never a shared one.

### Timestamps

Live presentation timestamps are on the session clock. The written file's timeline starts at approximately zero, at the first video sample the movie output wrote. `nearestResult` searches by timestamp, so results need a file-relative time.

Anchor on the presentation timestamp of the first data-output frame delivered after `fileOutput(_:didStartRecordingTo:from:)` fires, and subtract it. This is off by at most one or two frames, which at 240 fps is under 10 ms. That is fine for the diagnostic and for clip-boundary detection at the 10 samples/sec resolution the pipeline already works at. If a later consumer needs sub-frame alignment, the tightening is to compare the first live timestamp against the file's first sample after recording ends, and re-offset the results once.

### Thermal policy

Observe `ProcessInfo.thermalStateDidChangeNotification` for the duration of a recording.

- `.nominal`, `.fair`: normal stride.
- `.serious`: double the stride (5 samples/sec). Count the seconds spent here.
- `.critical`: stop inference for this recording. The queue drains nothing further; drops are counted. The recording is never touched.

Coverage under backoff is not deterministic. If a consumer needs full coverage, the post-recording backfill is `VideoFrameSampler` over the file restricted to the time ranges that were dropped or skipped. That is a follow-on, not part of this change.

### Where it lives

Prototype vehicle is the DEBUG-only pose diagnostic screen, reached today only through the `-screenshotPoseDiagnostic` launch argument. It already renders per-frame results and a summary, so it can show live results with no new UI. A debug flag on the camera screen enables the data output.

The payoff is `ProcessingPipeline`. Its `FrameSampling` protocol takes an `AVURLAsset`, so a live source cannot conform to it as written. The pipeline needs a second source abstraction that yields `(timestamp, tensor)` and feeds the same inference closure. That refactor is out of scope for the prototype and in scope for shipping.

## Acceptance gate

The unverified combination is a movie file output and a video data output both active **at 240 fps in 420v**. Apple's statement about iOS 16 is general and one format-dependent failure exists, so the general statement is not enough. Run on an A11 device (iPhone 8), 240 fps, a take of at least three minutes, with the debug flag on. All three must pass:

1. **The recording has no dropped frames.** `AVCaptureMovieFileOutput` does not report drops. Verify by reading the written file's video track and comparing its sample count against duration × nominal frame rate. Also compare against the same take with the flag off.
2. **Inference sustains about 10 samples/sec** with the queue near empty. Report the drop count and the maximum queue depth.
3. **Thermal state stays at or below `.fair`** for the whole take, and the recording keeps its frame rate under `.serious` if it is reached.

Pass all three: ship behind the flag, then remove the flag. Fail (1): the recorder is the constraint; move to the `AVAssetWriter` alternative. Fail (2) or (3) only: the model is the constraint; try `Interpreter.Options.threadCount` first, then the Core ML delegate, and rerun the gate. The Core ML delegate brings the Neural Engine into play and has its own op-support risk for MoveNet, so it is the second lever, not the first.

## Alternatives

**`AVCaptureVideoDataOutput` + `AVAssetWriter`, replacing the movie file output.** One frame stream feeds the encoder and the model; timestamps align for free; this is the pre-iOS 16 pattern and what most ML camera apps do. Rejected for now because it re-implements audio muxing, orientation, HEVC settings and slo-mo metadata in app code, and risks regressing a recorder that works. It is the fallback if the gate fails on the recording side.

**Read the file while it is being written.** With `movieFragmentInterval` set the file is readable mid-recording in principle, but `AVAssetReader` over a growing file is not a supported path. Rejected.

**Keep it post-hoc and speed up the decode.** Lower cost, no concurrency risk, but the decode is the floor: a 240 fps HEVC take still has to be decoded once after Stop. Kept as the baseline the gate compares against.

**Queue raw pixel buffers and preprocess later.** Simpler on paper. Not viable: the capture pool is small and retaining buffers stalls delivery. See "The constraint that shapes everything".

## Tradeoffs recorded

- Results are ready seconds after Stop, and the post-hoc decode of a 240 fps file is skipped.
- Coverage is not deterministic under thermal backoff or drops. Backfill from the file is the recovery, not part of this change.
- Two frame sources feed one model. The preprocess step is shared; the sampling abstraction is not, until the pipeline refactor.
- A lagging consumer has an explicit lifecycle. Every path that ends a recording also cancels its inference queue.
- The simulator has no camera. Every change on the capture side needs a device run; unit tests cover the stride, the queue bound and drop policy, the timestamp offset, and the thermal policy as pure functions.

## Out of scope

Live pose overlay on the preview, on-screen inference metrics for users, changing the recording format or codec, and the `ProcessingPipeline` source abstraction beyond noting that it is needed.
