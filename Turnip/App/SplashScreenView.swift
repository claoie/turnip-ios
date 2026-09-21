import SwiftUI

/// The launch splash: the app mark centered on black. `ContentView` owns the timer and the
/// fade-out into the real app — this view is just the static frame.
struct SplashScreenView: View {
    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
            }
    }
}

#Preview {
    SplashScreenView()
}
