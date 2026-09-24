import XCTest
@testable import Turnip

/// `GalleryFilter`'s predicate mapping is the reachable, testable seam for #176 — the `.album`
/// case carries a `PHAssetCollection`, which has no public initializer, the same reason
/// `VideoLibraryPagingTests` tests arithmetic rather than a real `PHFetchResult`.
final class GalleryFilterTests: XCTestCase {
    func testAllRestrictsToVideosOnly() {
        let format = GalleryFilter.all.predicate.predicateFormat
        XCTAssertTrue(format.contains("mediaType == 2"), format)
        XCTAssertFalse(format.contains("favorite"), format)
    }

    func testFavoritesRestrictsToVideosAndFavorited() {
        let format = GalleryFilter.favorites.predicate.predicateFormat
        XCTAssertTrue(format.contains("mediaType == 2"), format)
        XCTAssertTrue(format.contains("favorite == 1"), format)
    }

    func testAllEqualsItself() {
        XCTAssertEqual(GalleryFilter.all, GalleryFilter.all)
    }

    func testFavoritesEqualsItself() {
        XCTAssertEqual(GalleryFilter.favorites, GalleryFilter.favorites)
    }

    func testAllIsNotEqualToFavorites() {
        XCTAssertNotEqual(GalleryFilter.all, GalleryFilter.favorites)
    }
}
