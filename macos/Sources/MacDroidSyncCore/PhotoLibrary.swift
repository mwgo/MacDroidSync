import Foundation

#if canImport(Photos)
import Photos
#endif

/// What the app is actually able to do with the Photos library right now.
///
/// The reason this is not simply the system's authorization enum: on this
/// machine PhotoKit answered `.authorized` while showing zero assets, zero
/// albums and zero smart albums on a 318 GB library, with no error anywhere -
/// the system photo library pointed at a path inside the Trash, and
/// `unavailabilityReason` was `nil` throughout. A permission enum cannot express
/// that, so `blind` and `unavailable` do. Everything that decides whether to
/// accept a photo asks this, never `PHPhotoLibrary` directly.
public enum PhotoLibraryReadiness: Equatable {
    /// The user has not been asked yet. Asking is a user action, never a launch.
    case notDetermined
    /// The user said no, or a policy says no. Recoverable only in System Settings.
    case denied
    /// Authorized, and the library answers - the only state that imports.
    case ready
    /// Authorized, and the library is empty of even its own smart albums. That
    /// is not an empty library, it is a missing entitlement on the signature.
    case blind
    /// The library exists but cannot be opened right now, or did not answer in
    /// time. Transient: worth retrying later.
    case unavailable(String)

    /// Whether a photo may be imported. Everything else refuses the transfer,
    /// which leaves the file on the phone rather than losing it quietly.
    public var canImport: Bool { self == .ready }

    /// One short line for the menu and the settings tab.
    public var summary: String {
        switch self {
        case .notDetermined: return "waiting for your permission"
        case .denied: return "denied in System Settings"
        case .ready: return "ready"
        case .blind: return "authorized, but the library is not visible"
        case .unavailable(let why): return "unavailable: \(why)"
        }
    }
}

/// One file, on its way into the library.
public struct PhotoImportRequest: Equatable {
    /// The staged, already checksummed file.
    public let fileURL: URL
    /// The phone's key, for the log and for the index.
    public let key: String
    /// The name Photos should show.
    public let filename: String
    public let isVideo: Bool
    public let albumIdentifier: String?
    /// Carried over when a photo is replaced by an edited version.
    public var favorite: Bool = false
    public var hidden: Bool = false
    /// Where in the album the replaced version sat, so an edit keeps its place.
    public var albumIndex: Int?

    public init(
        fileURL: URL,
        key: String,
        filename: String,
        isVideo: Bool,
        albumIdentifier: String?,
        favorite: Bool = false,
        hidden: Bool = false,
        albumIndex: Int? = nil
    ) {
        self.fileURL = fileURL
        self.key = key
        self.filename = filename
        self.isVideo = isVideo
        self.albumIdentifier = albumIdentifier
        self.favorite = favorite
        self.hidden = hidden
        self.albumIndex = albumIndex
    }
}

/// What is worth carrying from an asset to the one that replaces it.
public struct PhotoAssetAttributes: Equatable {
    public let favorite: Bool
    public let hidden: Bool
    public let albumIndex: Int?

    public init(favorite: Bool, hidden: Bool, albumIndex: Int?) {
        self.favorite = favorite
        self.hidden = hidden
        self.albumIndex = albumIndex
    }
}

public enum PhotoDeletionOutcome: Equatable {
    /// The identifiers that are really gone from the library now.
    case deleted([String])
    /// Nothing was left to delete - the user had already removed them.
    case nothingToDo
    /// macOS asked and the answer was no. Never retried automatically: that
    /// would be a loop of system alerts.
    case cancelledByUser
    case failed(String)
}

public enum PhotoLibraryError: LocalizedError, Equatable {
    case notReady(String)
    case importFailed(String)
    /// The import reported success and the asset cannot be found afterwards.
    /// Seen in the wild when Photos merges an import into Recently Deleted.
    case assetNotFoundAfterImport

    public var errorDescription: String? {
        switch self {
        case .notReady(let why): return "the Photos library is not ready: \(why)"
        case .importFailed(let why): return why
        case .assetNotFoundAfterImport:
            return "Photos accepted the import but the photo is not in the library"
        }
    }
}

/// The seam between the photo sync and Apple Photos.
///
/// PhotoKit types never cross this protocol, so every decision above it is
/// testable against a fake - including the destructive half, which is the only
/// part of this app that can lose a user's data. `PhotoKitLibrary` below is the
/// only place in the whole project that imports Photos.
public protocol PhotoLibrary: AnyObject {
    var readiness: PhotoLibraryReadiness { get }
    /// Asks the user. Must only ever be called from something the user clicked.
    func requestAuthorization(_ done: @escaping (PhotoLibraryReadiness) -> Void)
    /// The album this app puts its imports in, created if it has to be.
    func ensureAlbum(named name: String, knownIdentifier: String?) throws -> String
    /// Imports one file and returns the asset identifier, verified by reading it
    /// back - an import that cannot be found afterwards is not an import.
    func importAsset(_ request: PhotoImportRequest) throws -> String
    /// Which of these identifiers still resolve. Everything that does not is a
    /// photo the user removed in Photos.
    func existing(_ identifiers: [String]) -> Set<String>
    func attributes(of identifier: String) -> PhotoAssetAttributes?
    /// Removes assets. macOS asks the user, once per call, and there is no API
    /// to suppress that - which is why this is only ever called from a menu item.
    func delete(_ identifiers: [String]) -> PhotoDeletionOutcome
}

#if canImport(Photos)

/// Apple Photos, through PhotoKit.
public final class PhotoKitLibrary: PhotoLibrary {

    /// How long any single PhotoKit question may take before it counts as
    /// unanswered. Measured on real hardware: with the system library pointing
    /// at a path inside the Trash, every fetch made CoreData retry eight times
    /// and never returned at all. A call without a deadline hangs the app.
    public static let deadline: TimeInterval = 8

    /// Imports and deletions run here, never on a session queue: a half gigabyte
    /// video would stall the heartbeat and drop the connection.
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-library")

    public init() {}

    // MARK: - Readiness

    public var readiness: PhotoLibraryReadiness {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        // `.limited` is documented as an iOS status, but the case exists on macOS
        // too, so it is named rather than left to the default. Either way the
        // probe decides: a library that cannot answer reads as blind or
        // unavailable, and nothing gets imported into it.
        case .authorized, .limited:
            if let reason = PHPhotoLibrary.shared().unavailabilityReason {
                return .unavailable(reason.localizedDescription)
            }
            return Self.probe()
        @unknown default:
            if let reason = PHPhotoLibrary.shared().unavailabilityReason {
                return .unavailable(reason.localizedDescription)
            }
            return Self.probe()
        }
    }

    public func requestAuthorization(_ done: @escaping (PhotoLibraryReadiness) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            // Deliberately ignoring the status handed back: `readiness` asks the
            // harder question, which is whether the library actually answers.
            let readiness = self?.readiness ?? .denied
            DispatchQueue.main.async { done(readiness) }
        }
    }

    /// Turns the probe into a verdict. A library that does not answer within the
    /// deadline is `unavailable` rather than `blind`: the first is worth retrying
    /// later, the second means the signature is wrong, and telling those two
    /// apart is the difference between "wait" and "go fix the build".
    private static func probe() -> PhotoLibraryReadiness {
        switch libraryAnswers() {
        case .some(true): return .ready
        case .some(false): return .blind
        case nil: return .unavailable("the Photos library did not answer within \(Int(deadline)) s")
        }
    }

    /// The capability probe. Every working library has exactly one "user
    /// library" smart album; zero means the process is authorized and blind,
    /// and nil means the library never answered.
    private static func libraryAnswers() -> Bool? {
        timed { PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil
        ).count }.map { $0 > 0 }
    }

    /// What the probe saw, for the log. Counts only - never any content.
    public func diagnostics() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
        let userLibrary = Self.timed { PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).count }
        let albums = Self.timed {
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).count
        }
        let assets = Self.timed {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            return PHAsset.fetchAssets(with: options).count
        }
        let unavailable = PHPhotoLibrary.shared().unavailabilityReason?.localizedDescription ?? "none"
        func show(_ value: Int?) -> String { value.map(String.init) ?? "no answer" }
        return "status=\(status) userLibrary=\(show(userLibrary)) albums=\(show(albums)) "
            + "assets(limit 1)=\(show(assets)) unavailable=\(unavailable)"
    }

    // MARK: - The album

    public func ensureAlbum(named name: String, knownIdentifier: String?) throws -> String {
        // By identifier, not by title: titles are not unique and the user is
        // free to rename the album without breaking anything.
        if let knownIdentifier {
            let found: String?? = Self.timed {
                PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [knownIdentifier], options: nil
                ).firstObject?.localIdentifier
            }
            if let existing = found ?? nil { return existing }
        }
        var placeholder: PHObjectPlaceholder?
        try perform {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier else {
            throw PhotoLibraryError.importFailed("Photos would not create the \(name) album")
        }
        Log.info("Created the \(name) album in Photos")
        return identifier
    }

    // MARK: - Importing

    public func importAsset(_ request: PhotoImportRequest) throws -> String {
        let readiness = self.readiness
        guard readiness.canImport else { throw PhotoLibraryError.notReady(readiness.summary) }

        let album = request.albumIdentifier.flatMap { identifier in
            PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject
        }

        var placeholder: PHObjectPlaceholder?
        try perform {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = request.filename
            // Leaving the staged file in place on purpose: moving a file that is
            // open or hardlinked fails, and keeping it means a failed import can
            // simply be retried from a file whose checksum is already verified.
            options.shouldMoveFile = false
            creation.addResource(with: request.isVideo ? .video : .photo,
                                 fileURL: request.fileURL, options: options)
            // Nothing sets creationDate or location: those have to come from the
            // file's own metadata, which is exactly what the verification proves.
            if request.favorite { creation.isFavorite = true }
            if request.hidden { creation.isHidden = true }
            guard let created = creation.placeholderForCreatedAsset else { return }
            placeholder = created
            if let album, let change = PHAssetCollectionChangeRequest(for: album) {
                if let index = request.albumIndex {
                    // An edited photo keeps the place its predecessor had.
                    change.insertAssets([created] as NSArray, at: IndexSet(integer: index))
                } else {
                    change.addAssets([created] as NSArray)
                }
            }
        }

        guard let identifier = placeholder?.localIdentifier else {
            throw PhotoLibraryError.importFailed("Photos accepted the file but named no asset")
        }
        // Never trust a write we have not read back. Photos has been seen to
        // report success while merging the import into Recently Deleted, where
        // the asset exists and is invisible.
        guard !existing([identifier]).isEmpty else {
            throw PhotoLibraryError.assetNotFoundAfterImport
        }
        return identifier
    }

    // MARK: - Reading back

    public func existing(_ identifiers: [String]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        let found = Self.timed { () -> [String] in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var live: [String] = []
            result.enumerateObjects { asset, _, _ in live.append(asset.localIdentifier) }
            return live
        }
        // No answer means "we do not know", and not knowing must never be read
        // as "the user deleted them": that would strand rows in removedByUser.
        return Set(found ?? identifiers)
    }

    public func attributes(of identifier: String) -> PhotoAssetAttributes? {
        let found: PhotoAssetAttributes?? = Self.timed {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else { return nil }
            return PhotoAssetAttributes(
                favorite: asset.isFavorite, hidden: asset.isHidden, albumIndex: nil
            )
        }
        return found ?? nil
    }

    // MARK: - Deleting

    public func delete(_ identifiers: [String]) -> PhotoDeletionOutcome {
        guard !identifiers.isEmpty else { return .nothingToDo }
        // Only ever identifiers this app recorded as its own imports. This is the
        // one call in the app that destroys user data, and it is not given a list
        // it did not build itself.
        let assets = Self.timed { () -> [PHAsset] in
            var found: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                .enumerateObjects { asset, _, _ in
                    if asset.canPerform(.delete) { found.append(asset) }
                }
            return found
        }
        guard let assets else {
            return .failed("the Photos library did not answer within \(Int(Self.deadline)) s")
        }
        // Everything already gone: no alert at all, which is the common case
        // once the user has tidied up in Photos themselves.
        guard !assets.isEmpty else { return .nothingToDo }

        let removed = assets.map(\.localIdentifier)
        do {
            // One change block for the whole batch, so macOS asks once rather
            // than once per photo.
            try perform { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
            return .deleted(removed)
        } catch let error as NSError {
            if error.code == Self.userCancelledCode { return .cancelledByUser }
            return .failed(error.localizedDescription)
        }
    }

    /// `PHPhotosErrorUserCancelled` from PHError.h, compared by value so this
    /// does not depend on how the error enum happens to be bridged into Swift.
    /// It is what macOS returns when the deletion alert is dismissed.
    private static let userCancelledCode = 3072

    // MARK: - Plumbing

    /// One change block, run to completion. Synchronous on purpose: the caller
    /// is already on the import queue, and straight-line code is far easier to
    /// reason about than a tree of completion handlers.
    private func perform(_ changes: @escaping () -> Void) throws {
        try PHPhotoLibrary.shared().performChangesAndWait(changes)
    }

    /// Runs one PhotoKit question with a deadline. The work goes on a thread of
    /// its own on purpose: a call that never returns strands that thread, and it
    /// must not be a thread anything else is waiting on.
    private static func timed<T>(_ work: @escaping () -> T) -> T? {
        let finished = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Thread.detachNewThread {
            let value = work()
            box.value = value
            finished.signal()
        }
        guard finished.wait(timeout: .now() + deadline) == .success else { return nil }
        return box.value
    }

    /// Hands one value across the semaphore; the wait is the barrier.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

#endif
