import Photos

/// Home's gallery filter selection (#176) — mirrors the Photos app's own filter menu: All
/// Items, Favorites, or a specific user album. "Edited" is deliberately not offered: PhotoKit
/// has no fetch-level predicate for it, only a per-asset `PHAssetResource` scan, which would
/// make every filter change O(library) instead of the fetch-level O(1) the other cases get —
/// see the PR this shipped in for the full reasoning.
enum GalleryFilter: Equatable {
    case all
    case favorites
    case album(PHAssetCollection)

    static func == (lhs: GalleryFilter, rhs: GalleryFilter) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all), (.favorites, .favorites):
            return true
        case (.album(let left), .album(let right)):
            return left.localIdentifier == right.localIdentifier
        default:
            return false
        }
    }

    /// The `PHFetchOptions.predicate` for this filter, always restricted to videos. Pure and
    /// separated from `VideoLibraryViewModel` so the mapping is unit-testable without a real
    /// `PHPhotoLibrary`.
    var predicate: NSPredicate {
        let video = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        switch self {
        case .all, .album:
            return video
        case .favorites:
            return NSCompoundPredicate(
                andPredicateWithSubpredicates: [video, NSPredicate(format: "favorite == YES")])
        }
    }
}
