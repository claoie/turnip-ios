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
        // Reserves space for the floating bar rather than overlaying it on top: each
        // page's own bottom-edge content (the record button, a resolution banner) then
        // stacks above it automatically via the normal safe-area nesting, instead of
        // needing hand-tuned padding to avoid the two colliding.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selectedTab: $selectedTab)
        }
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
        HStack(spacing: 40) {
            tabButton(.camera, systemImage: "camera.fill", label: "Camera")
            tabButton(.home, systemImage: "square.grid.2x2.fill", label: "Videos")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
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
