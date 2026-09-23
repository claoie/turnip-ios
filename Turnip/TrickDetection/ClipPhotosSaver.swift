import Foundation
import Photos

/// Failures saving an exported clip to Photos, typed so the caller can tell "send the
/// user to Settings" apart from "retry" without string-matching — the outcome
/// `ClipExportError`'s docstring says the exporter's typed errors exist to prevent.
enum ClipPhotosSaveError: LocalizedError, Equatable {
    /// The exported file was missing when the save was attempted.
    case missingInputFile(URL)
    /// The user denied the add-only Photos prompt. `restricted` is true when a
    /// parental-control / MDM restriction blocks access — in that case the user can't
    /// fix it from Settings, so the UI shouldn't send them there.
    case authorizationDenied(restricted: Bool)
    /// PhotoKit rejected the save after authorization was granted.
    case saveRejected(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingInputFile:
            return "This video is no longer available to save."
        case .authorizationDenied(let restricted):
            return restricted
                ? "Photos access is restricted on this device, so Turnip can't save to it."
                : "Turnip needs access to Photos to save this video. Allow access in Settings."
        case .saveRejected(let reason):
            return "Couldn't save this video to Photos. (\(reason))"
        }
    }
}

/// Writes exported clips into the user's Photos library.
///
/// Add-only: saving goes through the add-only authorization prompt
/// (`NSPhotoLibraryAddUsageDescription` in Info.plist covers the usage string). The v1 "nothing
/// leaves the device" promise still holds — every read this type does (`fetchAlbum(titled:)`
/// below, checking for an existing album before creating a duplicate) stays inside the device's
/// own Photos library, never the network. Per Apple's `PHAccessLevel.addOnly` documentation, an
/// app granted add-only access has read visibility limited to the assets and collections *it
/// created* — so that fetch can only ever find an album this saver made in an earlier call,
/// never a user's own pre-existing album of the same name, which is exactly the scope the
/// dedup needs.
struct ClipPhotosSaver: Sendable {
    /// Resolves the add-only Photos authorization, collapsed onto the app's
    /// shared Photos-domain authorization model (`PhotoLibraryAuthorization`,
    /// also used by the Home gallery).
    /// Injected so tests can drive the denial paths without a system prompt; production
    /// passes the live add-only request.
    var authorization: @Sendable () async -> PhotoLibraryAuthorization = {
        PhotoLibraryAuthorization(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    /// Saves one exported video file to Photos, returning the created asset's
    /// `PHAsset.localIdentifier`. The file must exist; the caller decides when to delete
    /// the sandbox copy afterwards.
    ///
    /// `albumTitle` is the Settings screen's "Save to an album" option
    /// (`TurnipSettings.albumDestination`): `nil` is the original default behavior — the asset
    /// is created with no album, landing wherever an ordinary Photos creation request lands it.
    /// A non-nil title adds the new asset to that album, creating it first if it doesn't already
    /// exist, both inside the one change block below so a save either fully lands (asset plus
    /// album membership) or fully doesn't.
    @discardableResult
    func saveVideo(at fileURL: URL, albumTitle: String? = nil) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClipPhotosSaveError.missingInputFile(fileURL)
        }
        switch await authorization() {
        case .authorized:
            break
        case .denied(let restricted):
            throw ClipPhotosSaveError.authorizationDenied(restricted: restricted)
        case .notDetermined, .limited:
            // requestAuthorization(for:) answers the prompt itself, so these mean a
            // status this build doesn't understand — fail closed rather than saving
            // into a library state we can't reason about.
            throw ClipPhotosSaveError.authorizationDenied(restricted: false)
        }
        // The change block can't throw, so a nil creation request is reported with a flag.
        // The commit itself throws a raw PhotoKit NSError (out of space, asset rejected);
        // it is wrapped so every failure out of this method is a ClipPhotosSaveError.
        var createdIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let placeholder = PHAssetCreationRequest
                    .creationRequestForAssetFromVideo(atFileURL: fileURL)?
                    .placeholderForCreatedAsset else { return }
                createdIdentifier = placeholder.localIdentifier
                guard let albumTitle else { return }
                if let existingAlbum = Self.fetchAlbum(titled: albumTitle) {
                    PHAssetCollectionChangeRequest(for: existingAlbum)?.addAssets([placeholder] as NSArray)
                } else {
                    PHAssetCollectionChangeRequest
                        .creationRequestForAssetCollection(withTitle: albumTitle)
                        .addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw ClipPhotosSaveError.saveRejected(reason: error.localizedDescription)
        }
        guard let createdIdentifier else {
            throw ClipPhotosSaveError.saveRejected(
                reason: "Photos rejected the creation request for \(fileURL.lastPathComponent)")
        }
        return createdIdentifier
    }

    /// An existing user album titled `title`, or `nil` when none exists yet — checked inside the
    /// same change block that would otherwise create a duplicate, so re-saving with the same
    /// album name adds to the one album instead of making a new one each time.
    private static func fetchAlbum(titled title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        ).firstObject
    }
}
