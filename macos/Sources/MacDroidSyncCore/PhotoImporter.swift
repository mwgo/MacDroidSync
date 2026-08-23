import Foundation

/// Everything the Mac does with a photo once its bytes have arrived.
///
/// This is where the index and the library meet, and it holds no PhotoKit types
/// of its own - `PhotoLibrary` is injected, so the tests drive every path here,
/// including the ones that delete.
///
/// The rule the whole type is arranged around: **nothing is ever removed from
/// Photos except from a menu item the operator clicked.** A deletion coming from
/// the phone only ever writes down an intention.
public final class PhotoImporter {

    public struct Acceptance: Equatable {
        public let accepted: Bool
        /// Why not, in words the phone can show and a person can act on.
        public let reason: String?

        static let yes = Acceptance(accepted: true, reason: nil)
        static func no(_ reason: String) -> Acceptance { Acceptance(accepted: false, reason: reason) }
    }

    private let library: PhotoLibrary
    private let index: PhotoIndexStore
    private let albumName: String
    private let readAlbumIdentifier: () -> String?
    private let writeAlbumIdentifier: (String) -> Void
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-importer")

    /// Called after a photo lands in Photos, for the menu and the notifications.
    public var onImported: ((String) -> Void)?
    /// Called when the number waiting to be removed changes.
    public var onPendingDeletionsChanged: ((Int) -> Void)?

    public init(
        library: PhotoLibrary,
        index: PhotoIndexStore = PhotoIndexStore(),
        albumName: String = "MacDroidSync",
        readAlbumIdentifier: @escaping () -> String? = { nil },
        writeAlbumIdentifier: @escaping (String) -> Void = { _ in }
    ) {
        self.library = library
        self.index = index
        self.albumName = albumName
        self.readAlbumIdentifier = readAlbumIdentifier
        self.writeAlbumIdentifier = writeAlbumIdentifier
    }

    public var readiness: PhotoLibraryReadiness { library.readiness }
    public var importedCount: Int { index.count(in: .imported) }
    public var pendingDeletionCount: Int { index.count(in: .pendingDelete) }
    public var removedByUserCount: Int { index.count(in: .removedByUser) }
    public var isFirstRun: Bool { index.isFirstRun }
    public var indexedKeys: [PhotoIndexEntry] { index.all }

    // MARK: - Before the bytes move

    /// Whether this offer is worth the bytes. Refusing here is cheap; refusing
    /// after a two gigabyte transfer is not.
    public func accepts(key: String, sha256: String?) -> Acceptance {
        let readiness = library.readiness
        guard readiness.canImport else {
            return .no("this Mac cannot reach its Photos library (\(readiness.summary))")
        }
        guard let entry = index.entry(for: key) else { return .yes }
        switch entry.state {
        case .removedByUser:
            // The user threw this away here. That decision outranks the phone,
            // and it holds even when the phone has edited the bytes since.
            return .no("removed from Photos on this Mac")
        case .imported, .pendingDelete:
            guard let sha256, sha256.lowercased() == entry.sha256.lowercased() else { return .yes }
            return .no("already in Photos")
        case .deletedByUs:
            return .yes
        }
    }

    // MARK: - Storing

    /// Hands one finished, checksum-verified file to Photos.
    ///
    /// The staged file is deleted only once the asset has been read back out of
    /// the library, so every failure leaves a file that can simply be retried.
    public func store(
        stagedFile: URL,
        key: String,
        filename: String,
        sha256: String,
        size: Int64,
        captureAt: Int64,
        isVideo: Bool
    ) throws {
        try queue.sync {
            let previous = index.entry(for: key)
            // An edit: the same key with different bytes. The new version goes in
            // first, in its own change block - that one never asks the user -
            // and only then is the old one written down as waiting to go. If the
            // operator never confirms, both versions sit in the album, which is
            // visible and explainable; nothing is lost either way.
            let carried = previous.flatMap { entry -> PhotoAssetAttributes? in
                guard entry.state == .imported, let identifier = entry.localIdentifier else { return nil }
                return library.attributes(of: identifier)
            }

            let albumIdentifier = try? library.ensureAlbum(
                named: albumName, knownIdentifier: readAlbumIdentifier()
            )
            if let albumIdentifier, albumIdentifier != readAlbumIdentifier() {
                writeAlbumIdentifier(albumIdentifier)
            }

            var request = PhotoImportRequest(
                fileURL: stagedFile,
                key: key,
                filename: filename,
                isVideo: isVideo,
                albumIdentifier: albumIdentifier
            )
            request.favorite = carried?.favorite ?? false
            request.hidden = carried?.hidden ?? false
            request.albumIndex = carried?.albumIndex

            let identifier = try library.importAsset(request)
            index.upsert(
                PhotoIndexEntry(
                    key: key,
                    sha256: sha256.lowercased(),
                    size: size,
                    captureAt: captureAt,
                    localIdentifier: identifier,
                    state: .imported,
                    importedAt: Message.now()
                )
            )
            try? FileManager.default.removeItem(at: stagedFile)

            // The version this one replaces is now waiting to be taken out.
            if let previous, previous.state == .imported,
               let stale = previous.localIdentifier, stale != identifier {
                index.upsert(
                    PhotoIndexEntry(
                        key: staleKey(for: key),
                        sha256: previous.sha256,
                        size: previous.size,
                        captureAt: previous.captureAt,
                        localIdentifier: stale,
                        state: .pendingDelete,
                        importedAt: previous.importedAt
                    )
                )
                Log.info("Replaced \(filename); the old copy is waiting to be removed from Photos")
            }
            onImported?(filename)
            report()
        }
    }

    /// The replaced version needs a row of its own, because the live key now
    /// belongs to the new asset. It is never offered to the phone, only used to
    /// remember which asset is still to be removed.
    private func staleKey(for key: String) -> String {
        "\(key)#replaced-\(Message.now())"
    }

    // MARK: - What the phone says is gone

    /// Writes down that these keys left the phone. Nothing is removed from
    /// Photos here, by design: that waits for the menu item.
    public func markGone(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        index.mark(keys, as: .pendingDelete)
        Log.info("\(keys.count) photo(s) left the phone and are waiting to be removed from Photos")
        report()
    }

    /// A key that came back - restored from the phone's bin, most likely. The
    /// pending removal is dropped rather than being carried out and re-imported.
    public func cancelPendingDeletion(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        index.mark(keys, as: .imported)
        Log.info("\(keys.count) photo(s) are back on the phone; they stay in Photos")
        report()
    }

    public func rename(from: String, to: String) {
        index.rename(from: from, to: to)
    }

    /// Notices what the user removed in Photos themselves. Anything our index
    /// claims to hold that no longer resolves becomes `removedByUser`, which is
    /// the state that stops the sync from putting it back.
    public func reconcile() {
        let entries = index.all.filter { $0.state == .imported || $0.state == .pendingDelete }
        let identifiers = entries.compactMap(\.localIdentifier)
        guard !identifiers.isEmpty else { return }
        let alive = library.existing(identifiers)
        let vanished = entries.filter { entry in
            guard let identifier = entry.localIdentifier else { return false }
            return !alive.contains(identifier)
        }
        guard !vanished.isEmpty else { return }
        // A pending deletion that vanished was done by hand: the intention is
        // fulfilled, not overruled, so it is recorded as ours rather than as a
        // rejection - which keeps the photo eligible if the phone offers it again.
        let removedByUser = vanished.filter { $0.state == .imported }.map(\.key)
        let alreadyDone = vanished.filter { $0.state == .pendingDelete }.map(\.key)
        index.mark(removedByUser, as: .removedByUser)
        index.markDeleted(alreadyDone)
        if !removedByUser.isEmpty {
            Log.info("\(removedByUser.count) photo(s) were removed in Photos; they will not come back")
        }
        report()
    }

    // MARK: - The one destructive step

    /// Removes what is waiting, in one batch, so macOS asks once.
    ///
    /// Only ever called from the menu item. The batch is pruned first: anything
    /// the user already deleted by hand is written off without appearing in the
    /// alert, so the common case shows no alert at all.
    public func flushDeletions() -> PhotoDeletionOutcome {
        queue.sync {
            let waiting = index.pendingDeletions
            guard !waiting.isEmpty else { return .nothingToDo }
            let identifiers = waiting.compactMap(\.localIdentifier)
            let alive = library.existing(identifiers)
            let gone = waiting.filter { entry in
                guard let identifier = entry.localIdentifier else { return true }
                return !alive.contains(identifier)
            }
            index.markDeleted(gone.map(\.key))

            let toDelete = waiting.filter { entry in
                guard let identifier = entry.localIdentifier else { return false }
                return alive.contains(identifier)
            }
            guard !toDelete.isEmpty else {
                report()
                return .nothingToDo
            }

            let outcome = library.delete(toDelete.compactMap(\.localIdentifier))
            switch outcome {
            case .deleted(let removed):
                let keys = toDelete
                    .filter { $0.localIdentifier.map(removed.contains) ?? false }
                    .map(\.key)
                index.markDeleted(keys)
                Log.info("Removed \(keys.count) photo(s) from Photos")
            case .cancelledByUser:
                // Left exactly as it was. Retrying by itself would be a loop of
                // system alerts, so the next attempt is the operator's move.
                Log.info("The removal was cancelled; \(toDelete.count) photo(s) are still waiting")
            case .failed(let why):
                Log.error("Could not remove photos: \(why)")
            case .nothingToDo:
                break
            }
            report()
            return outcome
        }
    }

    private func report() {
        let waiting = index.count(in: .pendingDelete)
        DispatchQueue.main.async { [weak self] in
            self?.onPendingDeletionsChanged?(waiting)
        }
    }
}
