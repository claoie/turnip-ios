import AVFoundation
import SwiftUI

/// Thin UIKit bridge for an `AVCaptureVideoPreviewLayer` — SwiftUI has no native camera
/// preview of its own — with the live pose skeleton drawn over it while recording.
///
/// The skeleton is drawn in UIKit rather than a SwiftUI overlay because only the preview
/// layer knows where a capture-device point lands on screen: `layerPointConverted` folds in
/// the connection's rotation, the front camera's mirroring and the aspect-fill crop, none of
/// which a SwiftUI `Canvas` over the view can see.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// In capture-device coordinates (the unrotated sensor picture, 0...1). Empty hides it.
    var poseKeypoints: [PoseKeypoint] = []

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.show(poseKeypoints)
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private static let jointRadius: CGFloat = 5
        private let limbLayer = CAShapeLayer()
        private let jointLayer = CAShapeLayer()

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("PreviewUIView.layerClass guarantees an AVCaptureVideoPreviewLayer")
            }
            return previewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            limbLayer.strokeColor = UIColor.systemGreen.cgColor
            limbLayer.lineWidth = 3
            limbLayer.lineCap = .round
            limbLayer.fillColor = nil
            jointLayer.fillColor = UIColor.systemGreen.cgColor
            layer.addSublayer(limbLayer)
            layer.addSublayer(jointLayer)
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("PreviewUIView is built in code")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            limbLayer.frame = bounds
            jointLayer.frame = bounds
        }

        /// Redraws the skeleton. Implicit layer animations are disabled: at ten poses a second an
        /// animated path would always be mid-tween, smearing the joints between two poses.
        func show(_ keypoints: [PoseKeypoint]) {
            let previewLayer = videoPreviewLayer
            let geometry = LivePoseOverlayGeometry(keypoints: keypoints) { keypoint in
                previewLayer.layerPointConverted(
                    fromCaptureDevicePoint: CGPoint(x: CGFloat(keypoint.x), y: CGFloat(keypoint.y)))
            }
            let limbs = CGMutablePath()
            for limb in geometry.limbs {
                limbs.move(to: limb.start)
                limbs.addLine(to: limb.end)
            }
            let joints = CGMutablePath()
            for joint in geometry.joints {
                joints.addEllipse(in: CGRect(
                    x: joint.x - Self.jointRadius, y: joint.y - Self.jointRadius,
                    width: Self.jointRadius * 2, height: Self.jointRadius * 2))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            limbLayer.path = limbs
            jointLayer.path = joints
            CATransaction.commit()
        }
    }
}
