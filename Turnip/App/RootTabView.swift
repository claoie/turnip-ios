import Photos
import SwiftUI

/// Which of the app's two pages is showing. Camera sorts first only because that's the
/// order the floating tab bar draws its icons in, left to right, and the order the pages
/// are declared in `RootTabView`'s `TabView` — swiping right from Home (its previous page)
/// reaches Camera the same way tapping the camera icon does.
enum MainTab: Hashable {
    case camera
    case home
}

/// The floating bar's approximate footprint, shared with `VideoGalleryView` so its grid
/// can reserve scroll room to clear the bar — it overlays the grid rather than pushing it
/// up, so without this the last row would be permanently stuck underneath it.
enum FloatingTabBarMetrics {
    static let clearance: CGFloat = 100
}

/// The app's root screen once past the splash: a swipeable, two-page `TabView` (Camera,
/// then the gallery) with a custom floating pill replacing the system tab bar — this app
/// has exactly two destinations, not the several a real `UITabBar` assumes.
///
/// Owns the one `VideoLibraryViewModel` shared by both pages, since a finished camera
/// recording needs to hand its asset to the same gallery/navigation state a tapped tile
/// would (`VideoLibraryViewModel.select(_:)`), and switching back to the gallery tab to
/// show that pick land needs to live somewhere both pages are reachable from.
struct RootTabView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            CameraCaptureView(onFinished: handleRecorded, onCancel: { selectedTab = .home })
                .tag(MainTab.camera)
            HomeView(viewModel: viewModel)
                .tag(MainTab.home)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // A page-style `TabView` lays its pages out inside the safe area, so the nested
        // `NavigationStack` never receives a top inset and its scroll views stop at the
        // status bar instead of running under it. Ignoring the safe area here hands the
        // full window to the pages; each page's own hosting controller then gets the real
        // insets back from UIKit, so nav bars and `.safeAreaInset` content stay put.
        .ignoresSafeArea()
        // An overlay, not a safe-area inset: the grid scrolls underneath it rather than
        // stopping short, so it reads as floating over the content instead of a docked
        // bar. Home-only and root-only (`viewModel.path.isEmpty`) per docs/UIUX.md — the
        // Camera page has its own cancel chevron back to Home, and a drilled-in clip
        // screen has its own back chevron, so the bar would be redundant chrome there.
        .overlay(alignment: .bottom) {
            if selectedTab == .home && viewModel.path.isEmpty {
                FloatingTabBar(selectedTab: $selectedTab)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTab == .home && viewModel.path.isEmpty)
    }

    /// A recording finished: save it to Photos (reusing the same `ClipPhotosSaver` the
    /// export flow already uses), then hand the resulting `PHAsset` to `viewModel.select`
    /// — the exact call a tapped gallery tile makes — and switch to the gallery tab so the
    /// user sees the pick land, Photos-app style.
    private func handleRecorded(_ fileURL: URL) {
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let identifier = try await ClipPhotosSaver().saveVideo(at: fileURL)
                guard let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject else { return }
                selectedTab = .home
                viewModel.select(asset)
            } catch {
                viewModel.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

/// The floating bottom nav: camera on the left, the gallery grid on the right. A custom
/// capsule rather than `TabView`'s own bar, which assumes more than two items.
private struct FloatingTabBar: View {
    @Binding var selectedTab: MainTab

    var body: some View {
        let buttons = HStack(spacing: 40) {
            tabButton(.camera, systemImage: "camera.fill", label: "Camera")
            tabButton(.home, systemImage: "square.grid.2x2.fill", label: "Videos")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)

        // Real Liquid Glass where the OS supports it (iOS 26+); `.ultraThinMaterial`
        // otherwise, matching how the bar already looked pre-Liquid Glass.
        Group {
            if #available(iOS 26.0, *) {
                buttons.glassEffect()
            } else {
                buttons.background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 12)
    }

    private func tabButton(_ tab: MainTab, systemImage: String, label: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.4))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-\(label.lowercased())")
    }
}
