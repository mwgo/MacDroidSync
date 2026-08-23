import XCTest
@testable import MacDroidSyncCore

/// The question this file answers: can anything move before the operator has
/// said so, and does a parked plan survive being interrupted?
final class PhotoSyncCoordinatorTests: XCTestCase {

    private var directory: URL!
    private var library: FakePhotoLibrary!
    private var importer: PhotoImporter!
    private var stateStore: PhotoSyncStateStore!
    private var coordinator: PhotoSyncCoordinator!
    /// Every request the coordinator put on the wire: nil keys means "send a
    /// manifest", a list means "send these".
    private var requests: [[String]?] = []

    private let day: Int64 = 86_400_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncPhotoCoordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = FakePhotoLibrary()
        importer = PhotoImporter(
            library: library,
            index: PhotoIndexStore(url: directory.appendingPathComponent("photos-index.json"))
        )
        stateStore = PhotoSyncStateStore(url: directory.appendingPathComponent("photos-state.json"))
        requests = []
        coordinator = makeCoordinator()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        library = nil
        importer = nil
        stateStore = nil
        coordinator = nil
        try super.tearDownWithError()
    }

    private func makeCoordinator(
        limits: PhotoSyncLimits = PhotoSyncLimits(approvalItems: 5, approvalBytes: 1_000_000,
                                                 itemsPerCycle: 3, bytesPerCycle: 1_000_000)
    ) -> PhotoSyncCoordinator {
        PhotoSyncCoordinator(
            importer: importer,
            state: stateStore,
            limits: limits,
            request: { [weak self] keys, _ in self?.requests.append(keys) }
        )
    }

    private func item(_ key: String, at captureAt: Int64, size: Int64 = 100,
                      excluded: PhotoExclusion? = nil) -> PhotoItem {
        PhotoItem(key: key, captureAt: captureAt, size: size, mime: "image/jpeg",
                  sha256: "h-\(key)", excluded: excluded)
    }

    private func manifest(_ items: [PhotoItem], from: Int64 = 0, gone: [String]? = nil,
                          id: String = "m1") -> PhotoPayload {
        PhotoPayload(manifestId: id, page: 1, pages: 1, count: items.count, from: from,
                     items: items, gone: gone)
    }

    private func storeImported(_ key: String, sha: String, captureAt: Int64) throws {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        try importer.store(stagedFile: file, key: key, filename: (key as NSString).lastPathComponent,
                           sha256: sha, size: 100, captureAt: captureAt, isVideo: false)
    }

    // MARK: - The gate

    func testTheFirstRunAsksForNothingAndParksTheWholePlan() {
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty, "not one offer may go on the wire before approval")
        XCTAssertEqual(coordinator.report.awaitingApproval, 1)
        XCTAssertNotNil(coordinator.report.approvalReason)
    }

    func testApprovingAsksForThePacedBatchOfExactlyWhatWasShown() throws {
        let items = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty)

        coordinator.approveWaitingPlan()
        XCTAssertEqual(requests.count, 1, "approving asks for a manifest to work from")
        XCTAssertNil(requests.first ?? nil)
        XCTAssertEqual(coordinator.report.awaitingApproval, 0)

        // The next manifest is the one that carries the approved keys out.
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        let asked = requests.compactMap { $0 }.last ?? []
        XCTAssertEqual(asked.count, 3, "one cycle carries at most itemsPerCycle")
        XCTAssertEqual(asked, ["k4", "k3", "k2"], "newest first")
    }

    /// An approval is not a licence for whatever arrives later: a *large* batch
    /// that turns up afterwards faces the gate on its own, while the keys that
    /// were approved keep moving.
    func testABigBatchArrivingAfterAnApprovalIsParkedOnItsOwn() throws {
        let shown = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(shown), ok: true, reason: nil)
        coordinator.approveWaitingPlan()
        requests.removeAll()

        // Six newcomers, over the approval threshold of five.
        let newcomers = (1...6).map { item("new\($0)", at: Int64(20 + $0) * day) }
        coordinator.handle(manifest: manifest(shown + newcomers), ok: true, reason: nil)

        XCTAssertEqual(coordinator.report.awaitingApproval, 6)
        let asked = requests.compactMap { $0 }.flatMap { $0 }
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("k") },
                      "only the approved keys were asked for")
        XCTAssertFalse(asked.isEmpty, "and the approved backlog still moves while they wait")
    }

    /// A small newcomer is ordinary work: below the threshold, nothing asks.
    func testASmallNewcomerAfterAnApprovalNeedsNoSecondApproval() throws {
        let shown = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(shown), ok: true, reason: nil)
        coordinator.approveWaitingPlan()
        requests.removeAll()

        coordinator.handle(manifest: manifest(shown + [item("one-more", at: 9 * day)]),
                           ok: true, reason: nil)
        XCTAssertEqual(coordinator.report.awaitingApproval, 0)
        XCTAssertTrue(requests.compactMap { $0 }.flatMap { $0 }.contains("one-more"))
    }

    func testAParkedPlanSurvivesARestart() {
        let items = (1...6).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        XCTAssertEqual(coordinator.report.awaitingApproval, 6)

        // A new coordinator over the same files is what a relaunch looks like.
        let reopened = makeCoordinator()
        XCTAssertEqual(reopened.report.awaitingApproval, 6)
        XCTAssertNotNil(reopened.report.approvalReason)
    }

    func testASmallEverydayBatchIsFetchedWithoutAsking() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        coordinator.handle(
            manifest: manifest([item("seen", at: 1 * day), item("new", at: 2 * day)]),
            ok: true, reason: nil
        )
        XCTAssertEqual(requests.compactMap { $0 }.last, ["new"])
        XCTAssertEqual(coordinator.report.awaitingApproval, 0)
    }

    func testTooLargeABatchParksInsteadOfDraining() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        let items = (1...6).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(coordinator.report.awaitingApproval, 6)
    }

    // MARK: - Refusals and half-truths

    func testARefusedManifestChangesNothingAndSaysWhy() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: PhotoPayload(), ok: false, reason: "no media permission")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(importer.pendingDeletionCount, 0)
        XCTAssertEqual(coordinator.report.refusal, "no media permission")
    }

    func testAnIncompleteManifestNeitherFetchesNorDeletes() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        let payload = PhotoPayload(manifestId: "m1", page: 1, pages: 3, count: 3, from: 0,
                                   items: [item("b", at: 6 * day)])
        coordinator.handle(manifest: payload, ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(importer.pendingDeletionCount, 0)
    }

    // MARK: - Deletions

    /// A cycle writes deletions down and touches nothing. macOS puts a
    /// confirmation alert in front of a removal, so a sync that removed by itself
    /// would put that alert on screen twice an hour, unasked.
    func testAVanishedPhotoIsWrittenDownAndNothingIsRemoved() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)

        XCTAssertTrue(library.deleteCalls.isEmpty, "a cycle may never remove by itself")
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertEqual(coordinator.report.pendingDeletions, 1)
        // The one that is still on the phone is untouched.
        XCTAssertEqual(importer.indexedKeys.first { $0.key == "a" }?.state, .imported)
    }

    func testATombstoneWritesDownAPhotoFromOutsideTheWindow() throws {
        try storeImported("old", sha: "h-old", captureAt: 1 * day)
        coordinator.handle(
            manifest: manifest([], from: 5 * day, gone: ["old"]), ok: true, reason: nil
        )
        XCTAssertTrue(library.deleteCalls.isEmpty)
        XCTAssertEqual(importer.pendingDeletionCount, 1)
    }

    func testRemovingFromTheMenuAppliesEverythingWaitingInOneBatch() throws {
        for name in ["a", "b", "c"] {
            try storeImported(name, sha: "h-\(name)", captureAt: 5 * day)
        }
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        XCTAssertEqual(importer.pendingDeletionCount, 2)

        let outcome = coordinator.removeWaitingPhotos()
        guard case .deleted(let removed) = outcome else { return XCTFail("expected deleted") }
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(library.deleteCalls.count, 1, "one batch means one alert")
        XCTAssertEqual(importer.pendingDeletionCount, 0)
    }

    /// A cancelled alert leaves everything exactly as it was, and asks nothing
    /// again by itself: an automatic retry would be a loop of system alerts.
    func testACancelledRemovalKeepsThePhotosWaiting() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([], from: 0), ok: true, reason: nil)
        library.deletionOutcome = .cancelledByUser

        XCTAssertEqual(coordinator.removeWaitingPhotos(), .cancelledByUser)
        XCTAssertEqual(importer.pendingDeletionCount, 1)

        // And a later cycle still does not remove it on its own.
        coordinator.handle(manifest: manifest([], from: 0, id: "m2"), ok: true, reason: nil)
        XCTAssertEqual(library.deleteCalls.count, 1)
    }

    func testAgedOutPhotosAreLeftAlone() throws {
        try storeImported("old", sha: "h-old", captureAt: 1 * day)
        coordinator.handle(manifest: manifest([], from: 5 * day), ok: true, reason: nil)
        XCTAssertEqual(importer.pendingDeletionCount, 0)
    }

    /// The ratio guard is now about what the operator is told, not about holding
    /// anything back: with removal behind a click, the count in the menu is the
    /// thing being judged, so it has to be right and it has to be loud.
    func testAMassDisappearanceIsWrittenDownAndStillRemovesNothing() throws {
        for index in 1...30 {
            try storeImported("k\(index)", sha: "h-k\(index)", captureAt: 5 * day)
        }
        coordinator.handle(manifest: manifest([], from: 0), ok: true, reason: nil)
        XCTAssertTrue(library.deleteCalls.isEmpty)
        XCTAssertEqual(coordinator.report.pendingDeletions, 30)
    }

    func testWhatIsWaitingSurvivesARestart() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([], from: 0), ok: true, reason: nil)
        XCTAssertEqual(makeCoordinator().report.pendingDeletions, 1)
    }

    func testACorrectionWritesDownWhatThePhoneSaysIsGone() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: PhotoPayload(page: 0, gone: ["a"]), ok: true, reason: nil)
        XCTAssertTrue(library.deleteCalls.isEmpty)
        XCTAssertEqual(importer.pendingDeletionCount, 1)
    }

    // MARK: - The report

    func testExcludedItemsAreReportedWithTheirReason() {
        coordinator.handle(
            manifest: manifest([
                item("DCIM/Camera/clip.mp4", at: 5 * day, size: 3_000_000_000, excluded: .size),
                item("DCIM/Camera/odd.jpg", at: 5 * day, excluded: .noLocation),
            ]),
            ok: true, reason: nil
        )
        let skipped = coordinator.report.skipped
        XCTAssertEqual(skipped.map(\.name), ["clip.mp4", "odd.jpg"])
        XCTAssertEqual(skipped.map(\.reason), [.size, .noLocation])
    }

    func testTheReportRemembersTheWindowThePhoneUsed() {
        coordinator.handle(manifest: manifest([], from: 5 * day), ok: true, reason: nil)
        XCTAssertEqual(coordinator.report.windowFrom,
                       Date(timeIntervalSince1970: Double(5 * day) / 1000))
        XCTAssertNotNil(coordinator.report.lastCycleAt)
    }

    func testSyncNowAsksForAManifest() {
        coordinator.syncNow()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first ?? nil)
    }

    func testDiscardingAParkedPlanLeavesNothingWaiting() {
        let items = (1...6).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        coordinator.discardWaitingPlan()
        XCTAssertEqual(coordinator.report.awaitingApproval, 0)
        XCTAssertTrue(requests.isEmpty)
    }
}
