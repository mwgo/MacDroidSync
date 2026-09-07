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
    /// Whether the phone is reachable at all.
    private var phoneIsThere = true
    /// Whether plain additions have to wait in the window as well.
    private var approvesAdditions = false
    /// Rows the coordinator said nobody had seen yet.
    private var announced: [[PhotoPendingAction]] = []

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
        // These tests are about the steady state, so the starting point is
        // already behind them. The tests that are about *taking* it live in
        // their own section below and start from a clean state.
        stateStore.update { $0.baselineAt = 1 }
        requests = []
        phoneIsThere = true
        approvesAdditions = false
        announced = []
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
            approvesAdditions: { [weak self] in self?.approvesAdditions ?? false },
            request: { [weak self] keys, _ in
                guard let self, self.phoneIsThere else { return false }
                self.requests.append(keys)
                return true
            }
        )
    }

    /// Everything currently waiting for a decision, by key.
    private var waitingKeys: [String] { coordinator.pendingActions.map(\.key) }

    private func waiting(_ kind: PhotoActionKind) -> [String] {
        coordinator.pendingActions.filter { $0.kind == kind }.map(\.key)
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

    func testAPlanOverTheLimitAsksForNothingAndParksTheWholePlan() {
        let items = (1...6).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty, "not one offer may go on the wire before approval")
        XCTAssertEqual(coordinator.report.awaitingApproval, 6)
        XCTAssertNotNil(coordinator.report.pendingReason)
    }

    func testSynchronisingAsksForThePacedBatchOfExactlyWhatWasPicked() throws {
        // Four plain additions would run by themselves; this is about what
        // happens once they are standing in the window.
        approvesAdditions = true
        let items = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty)

        let outcome = coordinator.synchronize(keys: waitingKeys)
        let asked = requests.compactMap { $0 }.last ?? []
        XCTAssertEqual(asked.count, 3, "one cycle carries at most itemsPerCycle")
        XCTAssertEqual(asked, ["k4", "k3", "k2"], "newest first")
        XCTAssertEqual(outcome.requested, 3)
        XCTAssertTrue(coordinator.pendingActions.isEmpty, "a decided row leaves the list")
    }

    /// Only the picked rows move. This is the whole point of the window over the
    /// old all-or-nothing menu item.
    func testOnlyThePickedRowsAreAskedFor() throws {
        // Four plain additions would run by themselves; this is about what
        // happens once they are standing in the window.
        approvesAdditions = true
        let items = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)

        coordinator.synchronize(keys: ["k2"])
        XCTAssertEqual(requests.compactMap { $0 }.last, ["k2"])
        XCTAssertEqual(waitingKeys.sorted(), ["k1", "k3", "k4"])
    }

    /// A click that never reached the phone must not look like it worked.
    func testRowsStayOnTheListWhenThePhoneCannotBeReached() throws {
        // Four plain additions would run by themselves; this is about what
        // happens once they are standing in the window.
        approvesAdditions = true
        let items = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        phoneIsThere = false

        let outcome = coordinator.synchronize(keys: ["k2"])
        XCTAssertEqual(outcome.notSent, 1)
        XCTAssertEqual(outcome.requested, 0)
        XCTAssertTrue(waitingKeys.contains("k2"))
    }

    /// An approval is not a licence for whatever arrives later: a *large* batch
    /// that turns up afterwards faces the gate on its own, while the keys that
    /// were approved keep moving.
    func testABigBatchArrivingAfterAnApprovalIsParkedOnItsOwn() throws {
        approvesAdditions = true
        let shown = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(shown), ok: true, reason: nil)
        coordinator.synchronize(keys: waitingKeys)
        approvesAdditions = false
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
        approvesAdditions = true
        let shown = (1...4).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(shown), ok: true, reason: nil)
        coordinator.synchronize(keys: waitingKeys)
        approvesAdditions = false
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
        XCTAssertNotNil(reopened.report.pendingReason)
        XCTAssertEqual(reopened.pendingActions.count, 6, "the rows themselves survive, not just a count")

        // And they can be acted on without waiting for a fresh manifest, because
        // each row carries the manifest item it came from.
        reopened.synchronize(keys: reopened.pendingActions.map(\.key))
        XCTAssertEqual(requests.compactMap { $0 }.last?.count, 3)
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
        XCTAssertEqual(waiting(.delete), ["b"], "and it is on the list, saying what it is")
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

    func testRemovingFromTheWindowAppliesThePickedRowsInOneBatch() throws {
        for name in ["a", "b", "c"] {
            try storeImported(name, sha: "h-\(name)", captureAt: 5 * day)
        }
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        XCTAssertEqual(importer.pendingDeletionCount, 2)

        let outcome = coordinator.synchronize(keys: waiting(.delete))
        XCTAssertEqual(outcome.deleted, 2)
        XCTAssertEqual(library.deleteCalls.count, 1, "one batch means one alert")
        XCTAssertEqual(importer.pendingDeletionCount, 0)
        XCTAssertTrue(coordinator.pendingActions.isEmpty)
    }

    /// Half a selection is still one alert, and the half left alone stays put.
    func testAnUnpickedRemovalIsLeftWaiting() throws {
        for name in ["a", "b", "c"] {
            try storeImported(name, sha: "h-\(name)", captureAt: 5 * day)
        }
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)

        let outcome = coordinator.synchronize(keys: ["b"])
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(library.deleteCalls.count, 1)
        XCTAssertEqual(waiting(.delete), ["c"])
        XCTAssertEqual(importer.indexedKeys.first { $0.key == "c" }?.state, .pendingDelete)
    }

    /// A cancelled alert leaves everything exactly as it was, and asks nothing
    /// again by itself: an automatic retry would be a loop of system alerts.
    func testACancelledRemovalKeepsThePhotosWaiting() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([], from: 0), ok: true, reason: nil)
        library.deletionOutcome = .cancelledByUser

        let outcome = coordinator.synchronize(keys: waiting(.delete))
        XCTAssertTrue(outcome.cancelledByUser)
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertEqual(waiting(.delete), ["a"], "and it is still on the list to try again")

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
        XCTAssertEqual(coordinator.pendingActions.filter { $0.issue == .bulkDeleteGuard }.count, 30,
                       "and every row says it is one of an unusually large batch")
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
        XCTAssertEqual(waiting(.problem).count, 2, "and each one is a row to decide about")
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

    // MARK: - What parks a cycle and what does not

    /// The everyday case, and the one the default is chosen for: photos turning
    /// up is the feature working, not a decision.
    func testAPlanOfOnlyAdditionsRunsByItself() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        coordinator.handle(
            manifest: manifest([item("seen", at: 1 * day), item("new", at: 2 * day)]),
            ok: true, reason: nil
        )
        XCTAssertEqual(requests.compactMap { $0 }.last, ["new"])
        XCTAssertTrue(coordinator.pendingActions.isEmpty)
    }

    func testWithTheFlagOnEvenAPlainAdditionWaits() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        approvesAdditions = true
        coordinator.handle(
            manifest: manifest([item("seen", at: 1 * day), item("new", at: 2 * day)]),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(waiting(.add), ["new"])
    }

    /// One deletion parks the whole plan, additions included. That is the point:
    /// the operator is shown everything at once and decides in one place.
    func testOneDeletionParksTheAdditionsWithIt() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        coordinator.handle(
            manifest: manifest([item("a", at: 5 * day), item("new", at: 6 * day)]),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty, "the addition waits with the deletion")
        XCTAssertEqual(waiting(.add), ["new"])
        XCTAssertEqual(waiting(.delete), ["b"])
    }

    /// So does an item the phone will not send: the operator asked for that.
    func testOneProblemParksTheAdditionsWithIt() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        coordinator.handle(
            manifest: manifest([
                item("seen", at: 1 * day),
                item("new", at: 6 * day),
                item("odd.jpg", at: 6 * day, excluded: .noLocation),
            ]),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(waiting(.add), ["new"])
        XCTAssertEqual(waiting(.problem), ["odd.jpg"])
    }

    /// A replaced version is a decision too, and it must not read as an addition.
    func testAnEditedPhotoIsShownAsAChangeAndParksTheCycle() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(
            manifest: manifest([PhotoItem(key: "a", captureAt: 5 * day, size: 100,
                                          mime: "image/jpeg", sha256: "h-a-edited")]),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(waiting(.change), ["a"])
    }

    /// A deletion is proposed by exactly one plan - writing it down moves the row
    /// out of the state deletions are computed from - so if the window did not
    /// carry it over, it would flash past and never be seen again.
    func testADeletionStaysOnTheListOverLaterCycles() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        XCTAssertEqual(waiting(.delete), ["b"])

        coordinator.handle(manifest: manifest([item("a", at: 5 * day)], id: "m2"),
                           ok: true, reason: nil)
        XCTAssertEqual(waiting(.delete), ["b"], "still there, and still explained")
    }

    /// And while it is there, nothing runs by itself either.
    func testNothingRunsByItselfWhileSomethingIsStillWaiting() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        requests.removeAll()

        coordinator.handle(
            manifest: manifest([item("a", at: 5 * day), item("new", at: 9 * day)], id: "m2"),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(waiting(.add), ["new"])
    }

    // MARK: - Ignoring, which is for good

    func testAnIgnoredAdditionIsNeverOfferedAgain() throws {
        approvesAdditions = true
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        coordinator.ignore(keys: ["a"])
        XCTAssertTrue(coordinator.pendingActions.isEmpty)

        coordinator.handle(manifest: manifest([item("a", at: 5 * day)], id: "m2"),
                           ok: true, reason: nil)
        XCTAssertTrue(requests.isEmpty, "never asked for again")
        XCTAssertTrue(coordinator.pendingActions.isEmpty, "and never asked about again")
        XCTAssertFalse(importer.accepts(key: "a", sha256: "h-a").accepted,
                       "and refused even if the phone offers it anyway")

        // A restart changes none of that: it is written in the index.
        let reopened = makeCoordinator()
        reopened.handle(manifest: manifest([item("a", at: 5 * day)], id: "m3"),
                        ok: true, reason: nil)
        XCTAssertTrue(reopened.pendingActions.isEmpty)
    }

    /// Ignoring a removal keeps the photo in Photos and stops the question.
    func testAnIgnoredRemovalKeepsThePhotoAndStopsAsking() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        coordinator.handle(manifest: manifest([], from: 0), ok: true, reason: nil)
        XCTAssertEqual(waiting(.delete), ["a"])

        coordinator.ignore(keys: ["a"])
        XCTAssertTrue(library.deleteCalls.isEmpty, "ignoring never deletes anything")
        XCTAssertEqual(importer.pendingDeletionCount, 0)
        XCTAssertEqual(importer.indexedKeys.first { $0.key == "a" }?.state, .ignoredByUser)

        coordinator.handle(manifest: manifest([], from: 0, id: "m2"), ok: true, reason: nil)
        XCTAssertTrue(coordinator.pendingActions.isEmpty, "the question does not come back")
    }

    func testAnIgnoredProblemStopsBeingReported() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        let odd = item("odd.jpg", at: 6 * day, excluded: .noLocation)
        coordinator.handle(manifest: manifest([item("seen", at: 1 * day), odd]),
                           ok: true, reason: nil)
        coordinator.ignore(keys: ["odd.jpg"])

        coordinator.handle(manifest: manifest([item("seen", at: 1 * day), odd, item("new", at: 7 * day)],
                                              id: "m2"),
                           ok: true, reason: nil)
        XCTAssertTrue(coordinator.pendingActions.isEmpty)
        XCTAssertEqual(requests.compactMap { $0 }.last, ["new"],
                       "and the cycle runs by itself again")
    }

    // MARK: - Telling the operator once

    func testUnseenRowsAreAnnouncedOnceAndNotOnEveryCycle() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        let first = expectation(description: "announced")
        coordinator.onDecisionsNeeded = { [weak self] rows in
            self?.announced.append(rows)
            first.fulfill()
        }
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)
        wait(for: [first], timeout: 1)
        XCTAssertEqual(announced.first?.map(\.key), ["b"])

        // The same list again says nothing: it is not news twice.
        coordinator.handle(manifest: manifest([item("a", at: 5 * day)], id: "m2"),
                           ok: true, reason: nil)
        let settled = expectation(description: "settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(announced.count, 1)
    }

    // MARK: - Upgrading

    /// A plan parked by the build that had no window must survive the upgrade,
    /// and so must the approvals - the store reads any decoding failure as
    /// "start from empty", which would silently undo the operator's decisions.
    func testAStateFileFromTheOldBuildIsCarriedOver() throws {
        let url = directory.appendingPathComponent("legacy-state.json")
        let legacy = """
        {"awaitingApproval":[{"k":"a","t":5,"s":100,"h":"h-a"}],        "approvalReason":"first run: nothing is imported before you have seen the report",        "approvedKeys":["z"],"approvedFirstRun":true,"skipped":[]}
        """
        try Data(legacy.utf8).write(to: url)

        let state = PhotoSyncStateStore(url: url).current
        XCTAssertEqual(state.pending.map(\.key), ["a"])
        XCTAssertEqual(state.pending.first?.kind, .add)
        XCTAssertNotNil(state.pending.first?.item, "so it can be acted on without a new manifest")
        XCTAssertEqual(state.approvedKeys, ["z"], "approvals are not lost by the upgrade")
        XCTAssertNotNil(state.baselineAt,
                        "an install that already reported once must never take a starting point")
        XCTAssertNotNil(state.pendingReason)
    }


    // MARK: - The starting point

    /// A fresh install has no backlog: what the phone already holds is where the
    /// counting starts, not five thousand items of work.
    private func makeVirginCoordinator() -> PhotoSyncCoordinator {
        stateStore.update { $0.baselineAt = nil }
        return makeCoordinator()
    }

    func testTheFirstCompleteManifestIsAdoptedAndNothingIsFetched() {
        let fresh = makeVirginCoordinator()
        let items = (1...5).map { item("k\($0)", at: Int64($0) * day) }
        fresh.handle(manifest: manifest(items), ok: true, reason: nil)

        XCTAssertTrue(requests.isEmpty, "a starting point costs nothing on the wire")
        XCTAssertTrue(fresh.pendingActions.isEmpty, "and asks nothing of the operator")
        XCTAssertEqual(fresh.report.awaitingApproval, 0)
        XCTAssertEqual(fresh.report.preexisting, 5)
        XCTAssertNotNil(fresh.report.baselineAt)
        XCTAssertTrue(fresh.report.skipped.isEmpty)
    }

    func testASecondManifestWithANewPhotoFetchesItByItself() {
        let fresh = makeVirginCoordinator()
        let items = (1...5).map { item("k\($0)", at: Int64($0) * day) }
        fresh.handle(manifest: manifest(items), ok: true, reason: nil)

        fresh.handle(manifest: manifest(items + [item("new", at: 9 * day)], id: "m2"),
                     ok: true, reason: nil)
        XCTAssertEqual(requests.compactMap { $0 }.last, ["new"])
        XCTAssertTrue(fresh.pendingActions.isEmpty)
    }

    /// The point of the whole thing: photos that were on the phone before this
    /// Mac started looking are not in Photos, so their disappearance is not a
    /// removal to confirm - there is nothing here to remove.
    func testAPhotoFromTheStartingPointLeavingThePhoneIsNotOfferedForRemoval() {
        let fresh = makeVirginCoordinator()
        let items = (1...3).map { item("k\($0)", at: Int64($0) * day) }
        fresh.handle(manifest: manifest(items), ok: true, reason: nil)

        fresh.handle(manifest: manifest(Array(items.dropLast()), id: "m2"), ok: true, reason: nil)
        XCTAssertTrue(fresh.pendingActions.isEmpty)
        XCTAssertEqual(fresh.report.pendingDeletions, 0)
        XCTAssertTrue(library.deleteCalls.isEmpty)
    }

    /// An edit is a change made after the starting point, so it is ordinary work.
    func testAnEditOfAPhotoFromTheStartingPointIsFetchedWithoutAsking() {
        let fresh = makeVirginCoordinator()
        fresh.handle(manifest: manifest([item("a", at: 5 * day)]), ok: true, reason: nil)

        let edited = PhotoItem(key: "a", captureAt: 5 * day, size: 100,
                               mime: "image/jpeg", sha256: "h-a-edited")
        fresh.handle(manifest: manifest([edited], id: "m2"), ok: true, reason: nil)
        XCTAssertEqual(requests.compactMap { $0 }.last, ["a"])
        XCTAssertTrue(fresh.pendingActions.isEmpty, "an edit is work, not a question")
    }

    /// Without this, one video the phone will never send would park every cycle
    /// for the rest of time.
    func testAnItemThePhoneWillNotSendIsSwallowedByTheStartingPoint() {
        let fresh = makeVirginCoordinator()
        let big = item("clip.mp4", at: 5 * day, size: 3_000_000_000, excluded: .size)
        fresh.handle(manifest: manifest([item("a", at: 5 * day), big]), ok: true, reason: nil)
        XCTAssertTrue(fresh.pendingActions.isEmpty)

        fresh.handle(manifest: manifest([item("a", at: 5 * day), big], id: "m2"),
                     ok: true, reason: nil)
        XCTAssertTrue(fresh.pendingActions.isEmpty, "and it stays swallowed")
        XCTAssertTrue(fresh.report.skipped.isEmpty)
    }

    func testTombstonesInTheFirstManifestChangeNothing() {
        let fresh = makeVirginCoordinator()
        fresh.handle(manifest: manifest([item("a", at: 5 * day)], gone: ["old"]),
                     ok: true, reason: nil)
        XCTAssertEqual(fresh.report.pendingDeletions, 0)
        XCTAssertTrue(fresh.pendingActions.isEmpty)
    }

    /// Half a manifest is not a picture of the phone, and a starting point taken
    /// from one would write off everything the missing page was holding.
    func testAnIncompleteFirstManifestIsNotAdopted() {
        let fresh = makeVirginCoordinator()
        let first = PhotoPayload(manifestId: "m1", page: 1, pages: 2, count: 2, from: 0,
                                 items: [item("a", at: 5 * day)])
        fresh.handle(manifest: first, ok: true, reason: nil)
        XCTAssertNil(stateStore.current.baselineAt)

        let second = PhotoPayload(manifestId: "m1", page: 2, pages: 2, count: 2, from: 0,
                                  items: [item("b", at: 6 * day)])
        fresh.handle(manifest: second, ok: true, reason: nil)
        XCTAssertNotNil(stateStore.current.baselineAt)
        XCTAssertEqual(fresh.report.preexisting, 2)
    }

    /// An install already tracking a library must never write it off.
    func testAnInstallThatHasAlreadySynchronisedTakesNoStartingPoint() throws {
        try storeImported("seen", sha: "h-seen", captureAt: 1 * day)
        let fresh = makeVirginCoordinator()

        fresh.handle(manifest: manifest([item("seen", at: 1 * day), item("new", at: 2 * day)]),
                     ok: true, reason: nil)
        XCTAssertNil(fresh.report.baselineAt)
        XCTAssertEqual(requests.compactMap { $0 }.last, ["new"], "the newcomer is work, not history")
    }

    /// "Start again" is a clean slate, not a flag. Leaving the old index in place
    /// made it a no-op on exactly the installs that ask for it: every key on the
    /// phone is already in there, decided one way or another, so a starting point
    /// - which only writes down keys nobody has spoken for - had nothing to write.
    func testStartingAgainForgetsEverythingFirst() throws {
        try storeImported("held", sha: "h-held", captureAt: 1 * day)
        coordinator.ignore(keys: [])
        importer.ignore([.never(item("refused", at: 1 * day))])
        XCTAssertEqual(importer.importedCount, 1)
        XCTAssertEqual(importer.ignoredCount, 1)

        coordinator.resetBaseline()
        XCTAssertEqual(importer.importedCount, 0, "the counters start from nothing")
        XCTAssertEqual(importer.ignoredCount, 0)
        XCTAssertTrue(importer.indexedKeys.isEmpty)
        XCTAssertNil(coordinator.report.baselineAt)
    }

    func testStartingAgainAdoptsWhateverThePhoneHasNow() throws {
        try storeImported("held", sha: "h-held", captureAt: 1 * day)
        coordinator.resetBaseline()

        coordinator.handle(
            manifest: manifest([item("held", at: 1 * day), item("stranger", at: 2 * day)]),
            ok: true, reason: nil
        )
        XCTAssertTrue(requests.isEmpty, "a starting point costs nothing on the wire")
        XCTAssertEqual(importer.preexistingCount, 2, "everything the phone has is the new baseline")
        XCTAssertEqual(importer.importedCount, 0)
        XCTAssertTrue(coordinator.pendingActions.isEmpty)
    }

    /// Nothing is removed from Photos by starting again: the assets stay, only
    /// the record of where they came from goes.
    func testStartingAgainRemovesNothingFromPhotos() throws {
        try storeImported("held", sha: "h-held", captureAt: 1 * day)
        coordinator.resetBaseline()
        XCTAssertTrue(library.deleteCalls.isEmpty)
    }

    /// The guard counts what this Mac actually holds, so a starting point of any
    /// size cannot quietly widen how many deletions look normal.
    func testTheStartingPointDoesNotWeakenTheBulkDeleteGuard() throws {
        // A hundred items adopted as the starting point...
        let fresh = makeVirginCoordinator()
        let older = (1...100).map { item("old\($0)", at: 4 * day) }
        fresh.handle(manifest: manifest(older), ok: true, reason: nil)
        XCTAssertEqual(fresh.report.preexisting, 100)

        // ...and twenty five this Mac actually holds.
        for index in 1...25 {
            try storeImported("k\(index)", sha: "h-k\(index)", captureAt: 5 * day)
        }

        // They all vanish at once. The guard counts what is held, not what was
        // adopted, so the starting point cannot quietly widen what looks normal.
        fresh.handle(manifest: manifest(older, id: "m2"), ok: true, reason: nil)
        XCTAssertEqual(fresh.pendingActions.filter { $0.issue == .bulkDeleteGuard }.count, 25)
    }

    /// An edit leaves the old copy waiting to be taken out of Photos. That is a
    /// removal, but not one the phone asked for - and the window has to say so,
    /// or it sits in the list looking exactly like a photo somebody deleted, and
    /// gets picked off with them.
    func testTheOldCopyOfAnEditedPhotoSaysWhyItIsBeingRemoved() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("b", sha: "h-b", captureAt: 5 * day)
        // "a" is edited on the phone: same key, different bytes.
        try storeImported("a", sha: "h-a-edited", captureAt: 5 * day)
        // "b" is deleted on the phone.
        coordinator.handle(
            manifest: manifest([PhotoItem(key: "a", captureAt: 5 * day, size: 100,
                                          mime: "image/jpeg", sha256: "h-a-edited")]),
            ok: true, reason: nil
        )

        let removals = coordinator.pendingActions.filter { $0.kind == .delete }
        XCTAssertEqual(removals.count, 2, "the replaced copy and the deleted photo")
        let replaced = removals.filter { $0.issue == .replacedVersion }
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced.first?.name, "a", "and it is named after its own file")
        XCTAssertEqual(removals.filter { $0.issue == nil }.map(\.key), ["b"])
    }

    /// And it keeps saying so on the cycles that follow, where the row is rebuilt
    /// from the index rather than from a plan.
    func testTheReasonSurvivesLaterCycles() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("a", sha: "h-a-edited", captureAt: 5 * day)
        let edited = PhotoItem(key: "a", captureAt: 5 * day, size: 100,
                               mime: "image/jpeg", sha256: "h-a-edited")
        coordinator.handle(manifest: manifest([edited]), ok: true, reason: nil)
        coordinator.handle(manifest: manifest([edited], id: "m2"), ok: true, reason: nil)

        XCTAssertEqual(
            coordinator.pendingActions.filter { $0.issue == .replacedVersion }.count, 1
        )
    }

    /// Approving "Update" has to mean the whole thing. The replaced copy only
    /// exists because that approval was given, so leaving it for a second round
    /// means the album holds two of everything ever edited.
    func testTheCopyAnEditReplacedIsTakenOutWithoutAskingAgain() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("a", sha: "h-a-edited", captureAt: 5 * day)
        XCTAssertEqual(importer.pendingDeletionCount, 1, "the old copy is waiting")

        let stale = try XCTUnwrap(importer.waitingDeletions.first?.localIdentifier)
        let outcome = coordinator.flushReplacedVersions()
        XCTAssertEqual(outcome, .deleted([stale]), "and it is the old asset that goes")
        XCTAssertEqual(importer.pendingDeletionCount, 0)
        XCTAssertEqual(library.deleteCalls.count, 1, "one call, so macOS asks once")
    }

    /// And it is strictly limited to those copies: a photo the phone deleted is
    /// a different question, and it still waits for its own answer.
    func testAPhotoThePhoneDeletedIsNotTakenOutWithIt() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        try storeImported("a", sha: "h-a-edited", captureAt: 5 * day)
        try storeImported("gone", sha: "h-gone", captureAt: 5 * day)
        coordinator.handle(
            manifest: manifest([PhotoItem(key: "a", captureAt: 5 * day, size: 100,
                                          mime: "image/jpeg", sha256: "h-a-edited")]),
            ok: true, reason: nil
        )
        XCTAssertEqual(importer.pendingDeletionCount, 2)

        coordinator.flushReplacedVersions()
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertEqual(waiting(.delete), ["gone"], "the phone's deletion still waits")
        XCTAssertEqual(library.deleteCalls.flatMap { $0 }.count, 1)
    }

    /// A removal that appears in the index *after* the list was last built has to
    /// be brought onto it, or it is invisible - no row, no count in the menu -
    /// until the next manifest turns up, which can be half an hour away.
    ///
    /// This is exactly how a replaced copy arrives: the operator approves the
    /// change, the list is cleared of what they decided, and the old copy only
    /// comes into existence later, when the bytes land.
    func testARemovalThatAppearsAfterTheListWasBuiltIsBroughtOntoIt() throws {
        try storeImported("a", sha: "h-a", captureAt: 5 * day)
        XCTAssertTrue(coordinator.pendingActions.isEmpty)

        // The edit lands: the old copy starts waiting, with nobody looking.
        try storeImported("a", sha: "h-a-edited", captureAt: 5 * day)
        XCTAssertEqual(importer.pendingDeletionCount, 1)
        XCTAssertTrue(coordinator.pendingActions.isEmpty, "not on the list on its own")

        coordinator.refreshPending()
        XCTAssertEqual(coordinator.pendingActions.count, 1)
        XCTAssertEqual(coordinator.pendingActions.first?.issue, .replacedVersion)
        XCTAssertEqual(coordinator.report.pendingDecisions, 1)
    }

    func testIgnoringAParkedPlanLeavesNothingWaiting() {
        let items = (1...6).map { item("k\($0)", at: Int64($0) * day) }
        coordinator.handle(manifest: manifest(items), ok: true, reason: nil)
        coordinator.ignore(keys: waitingKeys)
        XCTAssertEqual(coordinator.report.pendingDecisions, 0)
        XCTAssertTrue(requests.isEmpty, "ignoring never puts anything on the wire")
    }
}
