import AVFoundation
import SwiftUI

/// Thin UIKit bridge for an `AVCaptureVideoPreviewLayer` — SwiftUI has no native camera
/// preview of its own.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("PreviewUIView.layerClass guarantees an AVCaptureVideoPreviewLayer")
            }
            return previewLayer
        }
    }
}
