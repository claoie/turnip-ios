import CoreImage
import CoreVideo
import Foundation

/// Turns a source frame into a `PoseModelInput`: letterbox into the model's square input through
/// Core Image, then repack the rendered 32BGRA target as interleaved RGB.
///
/// Synchronous and callable from any thread, which is what lets the live path run it inside the
/// capture output's delegate callback and the file path run it from the sampler's handler, with a
/// single preprocess implementation between them. The source pixel format is not constrained:
/// `CIImage(cvPixelBuffer:)` accepts the camera's native 420v as readily as the file sampler's
/// 32BGRA, and the 32BGRA contract in `FramePreprocessor.packRGB` is on the rendered target.
///
/// `@unchecked Sendable` because `CIContext` carries no `Sendable` annotation; Apple documents it
/// as immutable and thread-safe, and this type holds nothing else that is mutable.
struct PoseInputPreparer: @unchecked Sendable {
    let preprocessor: FramePreprocessor
    private let ciContext: CIContext

    init(preprocessor: FramePreprocessor, ciContext: CIContext = CIContext()) {
        self.preprocessor = preprocessor
        self.ciContext = ciContext
    }

    func prepare(_ pixelBuffer: CVPixelBuffer) throws -> PoseModelInput {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let (transform, mapping) = try preprocessor.letterboxGeometry(forSourceExtent: sourceImage.extent)
        let outputBuffer = try preprocessor.makeTargetBuffer()
        ciContext.render(sourceImage.transformed(by: transform), to: outputBuffer)
        return PoseModelInput(tensor: try preprocessor.packRGB(from: outputBuffer), mapping: mapping)
    }
}
