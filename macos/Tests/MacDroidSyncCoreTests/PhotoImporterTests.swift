import XCTest
@testable import MacDroidSyncCore

/// A stand-in for Apple Photos, so the destructive half of this feature can be
/// tested at all. Every awkward answer the real library can give is available
/// here: a refused deletion, an asset that vanished, an authorized but invisible
/// library, an import that does not stick.
final class FakePhotoLibrary: PhotoLibrary {

    var readiness: PhotoLibraryReadiness = .ready
    var albumIdentifier = "album/1"
    var deletionOutcome: PhotoDeletionOutcome?
    var importFails: Error?
    /// Identifiers the library will admit to holding.
    var assets: Set<String> = []
    var attributesByIdentifier: [String: PhotoAssetAttributes] = [:]

    private(set) var imported: [PhotoImportRequest] = []
    private(set) var deleteCalls: [[String]] = []
    private(set) var albumRequests = 0
    private var nextAsset = 0

    func requestAuthorization(_ done: @escaping (PhotoLibraryReadiness) -> Void) {
        done(readiness)
    }

    func ensureAlbum(named name: String, knownIdentifier: String?) throws -> String {
        albumRequests += 1
        return knownIdentifier ?? albumIdentifier
    }

    func importAsset(_ request: PhotoImportRequest) throws -> String {
        if let importFails { throw importFails }
        imported.append(request)
        nextAsset += 1
        let identifier = "asset/\(nextAsset)"
        assets.insert(identifier)
        return identifier
    }

    func existing(_ identifiers: [String]) -> Set<String> {
        Set(identifiers).intersection(assets)
    }

    func attributes(of identifier: String) -> PhotoAssetAttributes? {
        attributesByIdentifier[identifier]
    }

    func delete(_ identifiers: [String]) -> PhotoDeletionOutcome {
        deleteCalls.append(identifiers)
        if let deletionOutcome { return deletionOutcome }
        assets.subtract(identifiers)
        return .deleted(identifiers)
    }
}

/// The question this file answers: can a photo be lost, duplicated, or brought
/// back from the dead by the code that talks to Photos?
final class PhotoImporterTests: XCTestCase {

    private var directory: URL!
    private var library: FakePhotoLibrary!
    private var index: PhotoIndexStore!
    private var importer: PhotoImporter!
    private var album: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncPhotoImporter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = FakePhotoLibrary()
        index = PhotoIndexStore(url: directory.appendingPathComponent("photos-index.json"))
        album = nil
        importer = PhotoImporter(
            library: library,
            index: index,
            readAlbumIdentifier: { [weak self] in self?.album },
            writeAlbumIdentifier: { [weak self] identifier in self?.album = identifier }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        library = nil
        index = nil
        importer = nil
        try super.tearDownWithError()
    }

    private func staged(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("bytes of \(name)".utf8).write(to: url)
        return url
    }

    // MARK: - Refusing before the bytes move

    func testABlindLibraryRefusesTheTransferInsteadOfImportingIntoNothing() {
        library.readiness = .blind
        let verdict = importer.accepts(key: "k", sha256: "aa")
        XCTAssertFalse(verdict.accepted)
        XCTAssertNotNil(verdict.reason)
    }

    func testTheSamePhotoIsRefusedRatherThanImportedTwice() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "AA", size: 10, captureAt: 5, isVideo: false)
        XCTAssertFalse(importer.accepts(key: "k", sha256: "aa").accepted)
    }

    func testChangedBytesUnderTheSameKeyAreAccepted() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        XCTAssertTrue(importer.accepts(key: "k", sha256: "bb").accepted)
    }

    func testWhatTheUserDeletedInPhotosIsRefusedForever() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        // The user removes it in Photos; the reconciliation notices.
        library.assets.removeAll()
        importer.reconcile()
        XCTAssertEqual(index.entry(for: "k")?.state, .removedByUser)
        XCTAssertFalse(importer.accepts(key: "k", sha256: "aa").accepted)
        // Even with new bytes: the deletion here outranks the phone.
        XCTAssertFalse(importer.accepts(key: "k", sha256: "different").accepted)
    }

    // MARK: - Importing

    func testAnImportRecordsTheAssetAndClearsTheStagedFile() throws {
        let file = try staged("a.jpg")
        try importer.store(stagedFile: file, key: "k", filename: "a.jpg",
                           sha256: "AA", size: 10, captureAt: 5, isVideo: false)
        let entry = index.entry(for: "k")
        XCTAssertEqual(entry?.state, .imported)
        XCTAssertEqual(entry?.sha256, "aa", "the hash is stored lowercase, as the protocol says")
        XCTAssertNotNil(entry?.localIdentifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFailedImportKeepsTheStagedFileAndRecordsNothing() throws {
        library.importFails = PhotoLibraryError.assetNotFoundAfterImport
        let file = try staged("a.jpg")
        XCTAssertThrowsError(try importer.store(stagedFile: file, key: "k", filename: "a.jpg",
                                                sha256: "aa", size: 10, captureAt: 5, isVideo: false))
        XCTAssertNil(index.entry(for: "k"), "nothing may be recorded that is not in the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "verified bytes are kept so the import can simply be retried")
    }

    func testTheAlbumIsCreatedOnceAndRemembered() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "a", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        XCTAssertEqual(album, "album/1")
        try importer.store(stagedFile: try staged("b.jpg"), key: "b", filename: "b.jpg",
                           sha256: "bb", size: 10, captureAt: 6, isVideo: false)
        XCTAssertEqual(library.imported.map(\.albumIdentifier), ["album/1", "album/1"])
    }

    // MARK: - Editing

    func testAnEditImportsFirstAndOnlyThenQueuesTheOldCopy() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "before", size: 10, captureAt: 5, isVideo: false)
        let first = index.entry(for: "k")?.localIdentifier
        library.attributesByIdentifier[first!] =
            PhotoAssetAttributes(favorite: true, hidden: false, albumIndex: 3)

        try importer.store(stagedFile: try staged("a2.jpg"), key: "k", filename: "a.jpg",
                           sha256: "after", size: 12, captureAt: 5, isVideo: false)

        // The new asset is in, under the live key.
        XCTAssertEqual(index.entry(for: "k")?.sha256, "after")
        XCTAssertNotEqual(index.entry(for: "k")?.localIdentifier, first)
        // Favourite and album position were carried over.
        XCTAssertEqual(library.imported.last?.favorite, true)
        XCTAssertEqual(library.imported.last?.albumIndex, 3)
        // And the old asset is waiting for the operator, not deleted.
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertTrue(library.deleteCalls.isEmpty)
        XCTAssertEqual(index.pendingDeletions.first?.localIdentifier, first)
    }

    // MARK: - Deleting, and only when told

    func testAPhoneSideDeletionOnlyWritesDownAnIntention() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        importer.markGone(["k"])
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertTrue(library.deleteCalls.isEmpty, "nothing may be removed without the menu item")
    }

    func testFlushingRemovesTheWaitingPhotosInOneBatch() throws {
        for name in ["a", "b", "c"] {
            try importer.store(stagedFile: try staged("\(name).jpg"), key: name, filename: "\(name).jpg",
                               sha256: name, size: 10, captureAt: 5, isVideo: false)
        }
        importer.markGone(["a", "c"])
        let outcome = importer.flushDeletions()

        XCTAssertEqual(library.deleteCalls.count, 1, "one batch means macOS asks once")
        XCTAssertEqual(library.deleteCalls.first?.count, 2)
        guard case .deleted(let removed) = outcome else { return XCTFail("expected deleted") }
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(index.entry(for: "a")?.state, .deletedByUs)
        XCTAssertEqual(index.entry(for: "b")?.state, .imported)
        XCTAssertEqual(importer.pendingDeletionCount, 0)
    }

    func testACancelledRemovalKeepsThePhotosWaitingAndAsksNothingAgain() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        importer.markGone(["k"])
        library.deletionOutcome = .cancelledByUser

        XCTAssertEqual(importer.flushDeletions(), .cancelledByUser)
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertEqual(library.deleteCalls.count, 1, "no automatic retry: that would be an alert loop")
    }

    /// The common case after the user has tidied up in Photos: there is nothing
    /// left to delete, so no alert should appear at all.
    func testPhotosTheUserAlreadyDeletedNeverReachTheAlert() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        importer.markGone(["k"])
        library.assets.removeAll()

        XCTAssertEqual(importer.flushDeletions(), .nothingToDo)
        XCTAssertTrue(library.deleteCalls.isEmpty)
        XCTAssertEqual(index.entry(for: "k")?.state, .deletedByUs)
    }

    func testFlushingWithNothingWaitingDoesNothing() {
        XCTAssertEqual(importer.flushDeletions(), .nothingToDo)
        XCTAssertTrue(library.deleteCalls.isEmpty)
    }

    // MARK: - Coming back

    func testAKeyThatReturnsFromTheBinKeepsItsAsset() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        let identifier = index.entry(for: "k")?.localIdentifier
        importer.markGone(["k"])
        importer.cancelPendingDeletion(["k"])

        XCTAssertEqual(index.entry(for: "k")?.state, .imported)
        XCTAssertEqual(index.entry(for: "k")?.localIdentifier, identifier)
        XCTAssertEqual(importer.pendingDeletionCount, 0)
    }

    /// A deletion that was carried out by hand is the intention fulfilled, not
    /// overruled - so it must not become `removedByUser`, which would block the
    /// photo from ever arriving again.
    func testAHandDeletedPendingRemovalIsRecordedAsDoneNotAsRejected() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        importer.markGone(["k"])
        library.assets.removeAll()
        importer.reconcile()
        XCTAssertEqual(index.entry(for: "k")?.state, .deletedByUs)
        XCTAssertTrue(importer.accepts(key: "k", sha256: "aa").accepted)
    }

    /// A library that does not answer must not be read as "the user deleted
    /// everything": that would strand every row in `removedByUser`.
    func testAnUnansweringLibraryChangesNoStates() throws {
        try importer.store(stagedFile: try staged("a.jpg"), key: "k", filename: "a.jpg",
                           sha256: "aa", size: 10, captureAt: 5, isVideo: false)
        // The real library answers "everything you asked about" on a timeout; the
        // fake does the same here by keeping the asset.
        importer.reconcile()
        XCTAssertEqual(index.entry(for: "k")?.state, .imported)
    }

    // MARK: - Naming

    func testVideosAreRecognisedByExtensionRatherThanByTheAnnouncedType() {
        XCTAssertTrue(PhotoImporter.isVideo(name: "clip.MP4", mime: "image/jpeg"))
        XCTAssertTrue(PhotoImporter.isVideo(name: "clip.mov", mime: nil))
        XCTAssertFalse(PhotoImporter.isVideo(name: "photo.jpg", mime: "video/mp4"))
        XCTAssertFalse(PhotoImporter.isVideo(name: "photo.heic", mime: nil))
        XCTAssertTrue(PhotoImporter.isVideo(name: "no-extension", mime: "video/mp4"))
    }
}
