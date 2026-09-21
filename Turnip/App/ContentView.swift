import SwiftUI

struct ContentView: View {
    @State private var showSplash = true

    private static let splashDuration: TimeInterval = 1.0
    private static let splashFadeDuration: TimeInterval = 0.4

    var body: some View {
        ZStack {
            RootTabView()
            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
            }
        }
        // The app is black-on-dark throughout — force dark appearance everywhere
        // rather than letting system controls and materials adapt to a light
        // system setting.
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashDuration) {
                withAnimation(.easeOut(duration: Self.splashFadeDuration)) {
                    showSplash = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
