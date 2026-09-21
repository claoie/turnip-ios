import SwiftUI

/// Suppresses the iOS 26 Liquid Glass scroll-edge effect at a scroll view's top edge.
/// `.toolbarBackground(.hidden, for: .navigationBar)` removes the nav bar's own
/// background, but on iOS 26 the scroll view separately draws a soft glass fade where
/// its content meets the top safe area — visible as a band under the status bar/nav
/// bar even with the bar itself transparent. No-op pre-iOS 26.
struct HiddenTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(nil, for: .top)
        } else {
            content
        }
    }
}
