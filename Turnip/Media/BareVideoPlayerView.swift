import AVFoundation
import SwiftUI

/// A video surface with no playback chrome — just the decoded frames.
///
/// SwiftUI's `VideoPlayer` always draws AVKit's transport controls and there is no
/// public way to hide them, so screens that draw their own scrub bar (Processing and
/// the clip list's tiles) wrap `AVPlayerLayer` directly instead.
struct BareVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        configure(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        configure(uiView.playerLayer)
    }

    private func configure(_ layer: AVPlayerLayer) {
        if layer.player !== player {
            layer.player = player
        }
        layer.videoGravity = videoGravity
        // `AVPlayerLayer` opts into extended dynamic range by default on an EDR-capable
        // display, which reads as blown-out/too-bright on ordinary (non-HDR-graded)
        // clips compared to the SDR thumbnail and the Photos app's player — disable it
        // so playback matches what the still frame and the system player show.
        if #available(iOS 17.0, *) {
            layer.wantsExtendedDynamicRangeContent = false
        }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // `unsafeDowncast` rather than `as!`: the cast is guaranteed by the `layerClass`
        // override above, not by a runtime check a lint rule should flag.
        var playerLayer: AVPlayerLayer { unsafeDowncast(layer, to: AVPlayerLayer.self) }
    }
}
