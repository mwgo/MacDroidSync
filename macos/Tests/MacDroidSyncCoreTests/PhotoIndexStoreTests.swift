import XCTest
@testable import MacDroidSyncCore

/// The question this file answers: does the Mac remember what it took and what
/// became of it, across restarts and across a damaged file?
final class PhotoIndexStoreTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncPhotoIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("photos-index.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    private func entry(
        _ key: String,
        sha: String = "aa",
        state: PhotoIndexState = .imported,
        importedAt: Int64 = 1
    ) -> PhotoIndexEntry {
        PhotoIndexEntry(key: key, sha256: sha, size: 10, captureAt: 100,
                        localIdentifier: "asset/\(key)", state: state, importedAt: importedAt)
    }

    func testAnEmptyStoreReportsAFirstRun() {
        let store = PhotoIndexStore(url: storeURL)
        XCTAssertTrue(store.isFirstRun)
        XCTAssertTrue(store.all.isEmpty)
    }

    func testOneImportEndsTheFirstRun() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a"))
        XCTAssertFalse(store.isFirstRun)
    }

    func testTheIndexSurvivesARestart() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a"))
        store.upsert(entry("b", state: .pendingDelete))

        let reopened = PhotoIndexStore(url: storeURL)
        XCTAssertEqual(reopened.all.count, 2)
        XCTAssertEqual(reopened.entry(for: "b")?.state, .pendingDelete)
    }

    func testUpsertingTheSameKeyReplacesRatherThanDuplicates() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a", sha: "before"))
        store.upsert(entry("a", sha: "after"))
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.entry(for: "a")?.sha256, "after")
    }

    func testRenameKeepsTheAssetAndMovesTheKey() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("DCIM/Camera/a.jpg"))
        store.rename(from: "DCIM/Camera/a.jpg", to: "DCIM/Camera/b.jpg")
        XCTAssertNil(store.entry(for: "DCIM/Camera/a.jpg"))
        XCTAssertEqual(store.entry(for: "DCIM/Camera/b.jpg")?.localIdentifier,
                       "asset/DCIM/Camera/a.jpg")
    }

    func testPendingDeletionsComeOutOldestFirstAndOnlyWithAnAsset() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("late", state: .pendingDelete, importedAt: 200))
        store.upsert(entry("early", state: .pendingDelete, importedAt: 100))
        store.upsert(entry("kept"))
        var staged = entry("staged", state: .pendingDelete)
        staged.localIdentifier = nil
        store.upsert(staged)

        XCTAssertEqual(store.pendingDeletions.map(\.key), ["early", "late"])
    }

    /// The point of `deletedByUs`: nobody rejected the photo on this Mac, so a
    /// store holding only those rows is a first run again as far as the report is
    /// concerned - while a photo the user deleted is not.
    func testOnlyOurOwnDeletionsLeaveTheStoreLookingUntouched() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a", state: .deletedByUs))
        XCTAssertTrue(store.isFirstRun)

        store.upsert(entry("b", state: .removedByUser))
        XCTAssertFalse(store.isFirstRun)
    }

    func testCountingByState() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a"))
        store.upsert(entry("b"))
        store.upsert(entry("c", state: .pendingDelete))
        XCTAssertEqual(store.count(in: .imported), 2)
        XCTAssertEqual(store.count(in: .pendingDelete), 1)
        XCTAssertEqual(store.count(in: .removedByUser), 0)
    }

    func testMarkingIgnoresKeysThatAreNotThere() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a"))
        store.mark(["a", "missing"], as: .pendingDelete)
        XCTAssertEqual(store.entry(for: "a")?.state, .pendingDelete)
        XCTAssertEqual(store.all.count, 1)
    }

    /// A damaged file must not take the app with it, and it must not be read as
    /// "the Mac has nothing, so delete nothing / import everything again" in a
    /// way that loses data. Empty is the safe direction: at worst a re-import.
    func testAnUnreadableFileLoadsAsEmpty() throws {
        try Data("not json at all".utf8).write(to: storeURL)
        let store = PhotoIndexStore(url: storeURL)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertTrue(store.isFirstRun)
    }

    func testTheFileGoesAwayWhenTheLastRowDoes() {
        let store = PhotoIndexStore(url: storeURL)
        store.upsert(entry("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }
}

/// The question this file answers: can a manifest that arrived in pieces be
/// mistaken for a complete picture of the phone? Because that mistake deletes
/// photos.
final class PhotoManifestAssemblerTests: XCTestCase {

    private func item(_ key: String) -> PhotoItem {
        PhotoItem(key: key, captureAt: 1_000, size: 10, mime: "image/jpeg", sha256: "aa")
    }

    private func page(
        _ page: Int,
        of pages: Int,
        count: Int,
        items: [PhotoItem],
        id: String = "m1",
        from: Int64 = 500,
        gone: [String]? = nil,
        skipped: Int? = nil
    ) -> PhotoPayload {
        PhotoPayload(manifestId: id, page: page, pages: pages, count: count, from: from,
                     items: items, gone: gone, skipped: skipped)
    }

    func testOnePageSnapshotCompletesImmediately() {
        let assembler = PhotoManifestAssembler()
        let outcome = assembler.accept(page(1, of: 1, count: 2, items: [item("a"), item("b")]))
        guard case .complete(let snapshot) = outcome else { return XCTFail("expected complete") }
        XCTAssertEqual(snapshot.items.map(\.key), ["a", "b"])
        XCTAssertEqual(snapshot.from, 500)
    }

    func testPagesArePutBackInOrderWhateverOrderTheyArriveIn() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(2, of: 2, count: 2, items: [item("b")]))
        let outcome = assembler.accept(page(1, of: 2, count: 2, items: [item("a")]))
        guard case .complete(let snapshot) = outcome else { return XCTFail("expected complete") }
        XCTAssertEqual(snapshot.items.map(\.key), ["a", "b"])
    }

    func testATruncatedManifestNeverCompletes() {
        let assembler = PhotoManifestAssembler()
        let outcome = assembler.accept(page(1, of: 5, count: 5, items: [item("a")]))
        XCTAssertEqual(outcome, .incomplete(received: 1, of: 5))
    }

    /// Every page present, and the count still wrong: refuse rather than guess,
    /// because guessing here is what deletes photos.
    func testAllPagesButTheWrongCountIsRejected() {
        let assembler = PhotoManifestAssembler()
        let outcome = assembler.accept(page(1, of: 1, count: 3, items: [item("a")]))
        guard case .rejected = outcome else { return XCTFail("expected rejected") }
    }

    func testAPhoneThatRefusesToDescribeItselfChangesNothing() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(1, of: 2, count: 2, items: [item("a")]))
        let outcome = assembler.accept(PhotoPayload(), ok: false, reason: "no media permission")
        XCTAssertEqual(outcome, .rejected("no media permission"))
        // And the half-collected snapshot is gone, not waiting to be finished.
        XCTAssertEqual(assembler.accept(page(2, of: 2, count: 2, items: [item("b")])),
                       .incomplete(received: 1, of: 2))
    }

    func testASecondSnapshotSupersedesAHalfCollectedOne() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(1, of: 2, count: 2, items: [item("a")], id: "m1"))
        let outcome = assembler.accept(page(1, of: 1, count: 1, items: [item("z")], id: "m2"))
        guard case .complete(let snapshot) = outcome else { return XCTFail("expected complete") }
        XCTAssertEqual(snapshot.manifestId, "m2")
        XCTAssertEqual(snapshot.items.map(\.key), ["z"])
    }

    func testPagesThatDisagreeAboutTheSnapshotAreRejected() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(1, of: 2, count: 4, items: [item("a")]))
        let outcome = assembler.accept(page(2, of: 2, count: 9, items: [item("b")]))
        guard case .rejected = outcome else { return XCTFail("expected rejected") }
    }

    func testAPageWithoutNumberingIsRejected() {
        let assembler = PhotoManifestAssembler()
        let outcome = assembler.accept(PhotoPayload(items: [item("a")]))
        guard case .rejected = outcome else { return XCTFail("expected rejected") }
    }

    func testACorrectionCarriesTombstonesOnItsOwn() {
        let assembler = PhotoManifestAssembler()
        let outcome = assembler.accept(PhotoPayload(page: 0, gone: ["x", "y"]))
        XCTAssertEqual(outcome, .correction(["x", "y"]))
    }

    func testTombstonesAndSkipsRideAlongWithTheSnapshot() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(1, of: 2, count: 2, items: [item("a")], gone: ["old"], skipped: 3))
        let outcome = assembler.accept(page(2, of: 2, count: 2, items: [item("b")], gone: ["older"]))
        guard case .complete(let snapshot) = outcome else { return XCTFail("expected complete") }
        XCTAssertEqual(snapshot.tombstones, ["old", "older"])
        XCTAssertEqual(snapshot.skipped, 3)
    }

    func testResetForgetsAHalfCollectedSnapshot() {
        let assembler = PhotoManifestAssembler()
        _ = assembler.accept(page(1, of: 2, count: 2, items: [item("a")]))
        assembler.reset()
        XCTAssertEqual(assembler.accept(page(2, of: 2, count: 2, items: [item("b")])),
                       .incomplete(received: 1, of: 2))
    }
}
