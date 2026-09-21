import SwiftUI

/// The app's one full-width prominent call-to-action, pinned to the bottom of a
/// screen via `.safeAreaInset`: "Start analysis", "Export N clips", "Done". A shared
/// component rather than three ad hoc buttons — `.borderedProminent`'s background
/// ignores a `.frame(maxWidth:)` applied to the `Button` itself, so a hand-rolled
/// version quietly renders as a small centered pill instead of the full-width bar it
/// looks like everywhere else; the frame has to go on the label, which is the one
/// thing every ad hoc copy got wrong. Wrapping that gotcha here means every caller
/// gets the real full-width button.
struct PrimaryActionBar: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
        .padding()
        .background(.thinMaterial)
    }
}
