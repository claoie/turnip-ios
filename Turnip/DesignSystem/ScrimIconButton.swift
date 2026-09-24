import SwiftUI

/// A circular icon button floating directly over media (video/photo content), with a
/// translucent dark scrim behind the glyph for contrast against an arbitrary frame —
/// the camera screen's cancel button, the clip grid's expand button. One shared
/// definition instead of each screen re-declaring the same circle-plus-scrim
/// background; `diameter`/`font` stay per-call-site since a full-screen overlay
/// button and a small in-tile corner button are genuinely different scales, not the
/// same button drifting.
struct ScrimIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var diameter: CGFloat = 44
    var font: Font = .body.weight(.semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.black.opacity(0.4), in: Circle())
                // Touch-target floor (docs/ACCESSIBILITY.md's 44x44 pt minimum), applied
                // on the label so it's part of the Button's own hit-testing region —
                // same placement `BackChevronButton` uses. A no-op at the 44 pt default;
                // expands the tappable area around a smaller `diameter` without
                // changing what's drawn.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
