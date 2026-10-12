import SwiftUI

extension View {
    /// Grows the region a finger has to find out to the 44 pt floor
    /// (`docs/ACCESSIBILITY.md`), without changing what the view lays out.
    ///
    /// An inset rather than a `frame`: a frame re-centers the drawn glyph inside the larger box
    /// and moves it — off a tile's corner, or by stretching the pill around it — while the whole
    /// point here is to leave the drawing where it is. Applied to a button's label rather than
    /// to the button, so it becomes part of that button's own hit-testing region, the same
    /// placement `ScrimIconButton` uses for its frame.
    ///
    /// On iOS 17 and later this also moves VoiceOver's focus rectangle, which is drawn from the
    /// accessibility content shape. That shape kind is iOS 17+ while the deployment floor is
    /// 16.0 (`project.yml`), so below 17 the interaction shape widens alone: the control is
    /// still reachable and still hit-testable at 44 pt, and only the focus rectangle stays
    /// drawn tight to the glyph.
    @ViewBuilder
    func touchTarget(insetBy inset: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            contentShape([.interaction, .accessibility], Rectangle().inset(by: -inset))
        } else {
            contentShape(Rectangle().inset(by: -inset))
        }
    }
}
