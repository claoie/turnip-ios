import SwiftUI

/// The flow's custom back chevron: used in place of the system back button on
/// screens that need to pop further than one level (straight to Home, or committing
/// edits before closing) — a plain chevron with no title, Photos-app style. One
/// shared 44×44 tap target instead of three near-identical copies.
struct BackChevronButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
