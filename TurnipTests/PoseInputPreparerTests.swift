import CoreImage
import CoreVideo
import XCTest
@testable import Turnip

/// The one preprocess implementation both frame sources feed through. The live path's whole
/// premise is that the camera's native 420v frames can go straight in without an ISP conversion
/// to BGRA, so that is exercised here alongside the file path's BGRA.
final class PoseInputPreparerTests: XCTestCase {
    private let preparer = PoseInputPreparer(preprocessor: FramePreprocessor(targetWidth: 256, targetHeight: 256))

    func testBGRASourcePacksAFullTensorWithLetterboxGeometry() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA)

        let input = try preparer.prepare(source)

        XCTAssertEqual(input.tensor.count, 256 * 256 * 3)
        XCTAssertEqual(input.mapping.scale, 256.0 / 640, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetX, 0, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetY, (256 - 360 * 256.0 / 640) / 2, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    /// The camera's native format. `CIImage(cvPixelBuffer:)` handles the planar-to-RGB conversion,
    /// and the 32BGRA contract is on the rendered target, not the source.
    func testBiPlanar420vSourceIsAccepted() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill420v(source, luma: 200)

        let input = try preparer.prepare(source)

        XCTAssertEqual(input.tensor.count, 256 * 256 * 3)
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 640, height: 360))
        // The letterboxed content is bright and the pad stays black: sample the middle row and a
        // pad row. Video-range luma 200 with neutral chroma converts to a light gray.
        let middle = pixel(in: input.tensor, x: 128, y: 128)
        XCTAssertGreaterThan(middle.red, 150, "content row was not rendered from the 420v source")
        XCTAssertGreaterThan(middle.green, 150)
        XCTAssertGreaterThan(middle.blue, 150)
        let pad = pixel(in: input.tensor, x: 128, y: 2)
        XCTAssertEqual(pad.red, 0, "letterbox pad must stay zeroed")
        XCTAssertEqual(pad.green, 0)
        XCTAssertEqual(pad.blue, 0)
    }

    /// The crux of `prepare`'s live-path change: a rotated sensor buffer is uprighted before the
    /// letterbox runs, so the mapping (and therefore the frame-normalized keypoints it later
    /// inverts) is computed against the rotated dimensions, not the raw sensor ones — matching
    /// what the file path already gets for free from `VideoFrameSampler`'s `preferredTransform`.
    func testRotationUprightsBeforeLetterboxingSoTheMappingReflectsTheRotatedExtent() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA)

        let input = try preparer.prepare(source, rotationDegrees: 90)

        // 640x360 rotated 90° clockwise is 360x640 — portrait, the same shape a portrait
        // recording's movie connection reports — so the letterbox pads left/right, not top/bottom.
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 360, height: 640))
        XCTAssertEqual(input.mapping.scale, 256.0 / 640, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetY, 0, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetX, (256 - 360 * 256.0 / 640) / 2, accuracy: 1e-6)
    }

    /// The default matches the unrotated call exactly, so the file path (which never passes
    /// `rotationDegrees`) is unaffected by this parameter existing.
    func testRotationDefaultsToZeroMatchingTheUnrotatedCall() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA)

        let implicit = try preparer.prepare(source)
        let explicitZero = try preparer.prepare(source, rotationDegrees: 0)

        XCTAssertEqual(implicit.mapping, explicitZero.mapping)
    }

    func testDegenerateSourceThrowsInsteadOfProducingGeometry() throws {
        // A 1x1 source is valid; the degenerate case is exercised through the preprocessor's
        // own guard, which `prepare` reaches with the CIImage extent.
        let tiny = try makeBuffer(width: 1, height: 1, format: kCVPixelFormatType_32BGRA)
        XCTAssertNoThrow(try preparer.prepare(tiny))
        XCTAssertThrowsError(
            try preparer.preprocessor.letterboxGeometry(forSourceExtent: .zero))
    }

    // MARK: - Fixtures

    private struct RGB {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private func pixel(in tensor: Data, x: Int, y: Int) -> RGB {
        let offset = (y * 256 + x) * 3
        return RGB(red: tensor[offset], green: tensor[offset + 1], blue: tensor[offset + 2])
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed for format \(format) with status \(status)")
        }
        return buffer
    }

    /// Solid luma with neutral chroma (128) in both planes.
    private func fill420v(_ buffer: CVPixelBuffer, luma: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(lumaPlane, Int32(luma), bytes)
        }
        if let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(chromaPlane, 128, bytes)
        }
    }
}
