import XCTest
@testable import MacDroidSyncCore

/// The question this file answers: can the photo sync destroy anything it should
/// not? Every test below stands for one way the library could be emptied, a
/// deleted photo could come back, or 46 GB could start moving unasked.
final class PhotoDeltaTests: XCTestCase {

    // MARK: - Helpers

    private let day: Int64 = 86_400_000

    private func item(
        _ key: String,
        at captureAt: Int64,
        size: Int64 = 1_000,
        sha: String? = "aa",
        excluded: PhotoExclusion? = nil
    ) -> PhotoItem {
        PhotoItem(key: key, captureAt: captureAt, size: size, mime: "image/jpeg",
                  sha256: sha, excluded: excluded)
    }

    private func entry(
        _ key: String,
        at captureAt: Int64,
        size: Int64 = 1_000,
        sha: String = "aa",
        state: PhotoIndexState = .imported
    ) -> PhotoIndexEntry {
        PhotoIndexEntry(key: key, sha256: sha, size: size, captureAt: captureAt,
                        localIdentifier: "asset/\(key)", state: state, importedAt: 1)
    }

    // MARK: - Deleting

    /// A complete, honest manifest that happens to be empty must not be read as
    /// "the user deleted everything".
    func testEmptyButCompleteManifestRefusesToDeleteTheLibrary() {
        let index = (1...300).map { entry("k\($0)", at: 5 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: [], from: day, index: index, isFirstRun: false)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertEqual(plan.refusedDelete.count, 300)
    }

    /// Twenty vanished photos out of three hundred is plausible tidying, so it
    /// goes through; the guard is for the runaway case.
    func testASmallDisappearanceIsDeletedNormally() {
        var index = (1...300).map { entry("k\($0)", at: 5 * day, sha: "h\($0)") }
        let items = index.dropFirst(15).map { item($0.key, at: $0.captureAt, sha: $0.sha256) }
        index = Array(index)
        let plan = PhotoDelta.plan(items: items, from: day, index: index, isFirstRun: false)
        XCTAssertEqual(plan.delete.count, 15)
        XCTAssertTrue(plan.refusedDelete.isEmpty)
    }

    /// The rule the whole design rests on: a photo that fell out of the window is
    /// not a deletion, because the Mac only ever judges what the phone declared.
    func testAgedOutEntryIsNotDeleted() {
        let index = [entry("old", at: 1 * day), entry("new", at: 10 * day)]
        let plan = PhotoDelta.plan(
            items: [item("new", at: 10 * day)], from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.refusedDelete.isEmpty)
    }

    /// And the reason tombstones exist: without them, deleting last year's photo
    /// on the phone could never reach the Mac, because it is outside the window.
    func testTombstoneDeletesOutsideTheWindow() {
        let index = [entry("old", at: 1 * day)]
        let plan = PhotoDelta.plan(
            items: [], from: 5 * day, tombstones: ["old"], index: index, isFirstRun: false
        )
        XCTAssertEqual(plan.delete.map(\.key), ["old"])
    }

    /// A video the phone refuses to send is listed, not omitted - otherwise it
    /// would look exactly like a deletion.
    func testExcludedItemIsNeitherWantedNorDeleted() {
        let index = [entry("clip.mp4", at: 6 * day)]
        let plan = PhotoDelta.plan(
            items: [item("clip.mp4", at: 6 * day, size: 3_000_000_000, excluded: .size)],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(plan.want.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertEqual(plan.excluded.map(\.key), ["clip.mp4"])
    }

    // MARK: - Not coming back

    func testWhatTheUserDeletedInPhotosIsNotImportedAgain() {
        let index = [entry("gone", at: 6 * day, state: .removedByUser)]
        let plan = PhotoDelta.plan(
            items: [item("gone", at: 6 * day)], from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// Even edited on the phone: new bytes are still the photo the user threw
    /// away here, and the Mac's decision outranks the phone's.
    func testAnEditedPhotoTheUserDeletedStillDoesNotComeBack() {
        let index = [entry("gone", at: 6 * day, sha: "old", state: .removedByUser)]
        let plan = PhotoDelta.plan(
            items: [item("gone", at: 6 * day, sha: "new")], from: 5 * day, index: index,
            isFirstRun: false
        )
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// The other side of that coin, and the reason `deletedByUs` is a separate
    /// state: we removed it because the phone had, so when the phone has it
    /// again it is welcome back. Nobody rejected it here.
    func testAPhotoWeRemovedComesBackWhenThePhoneHasItAgain() {
        let index = [entry("k", at: 6 * day, state: .deletedByUs)]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day)], from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertEqual(plan.want.map(\.key), ["k"])
    }

    func testRestoredFromTheBinCancelsThePendingDeletion() {
        let index = [entry("back", at: 6 * day, sha: "same", state: .pendingDelete)]
        let plan = PhotoDelta.plan(
            items: [item("back", at: 6 * day, sha: "same")], from: 5 * day, index: index,
            isFirstRun: false
        )
        XCTAssertEqual(plan.cancelPendingDelete, ["back"])
        XCTAssertTrue(plan.want.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    // MARK: - Renames

    func testARenameCostsNoBytesAndNoDeletion() {
        let index = [entry("DCIM/Camera/a.jpg", at: 6 * day, sha: "same")]
        let plan = PhotoDelta.plan(
            items: [item("DCIM/Camera/b.jpg", at: 6 * day, sha: "same")],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertEqual(plan.renames, [PhotoRename(from: "DCIM/Camera/a.jpg", to: "DCIM/Camera/b.jpg")])
        XCTAssertTrue(plan.want.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    /// The same bytes under a second name while the first is still there is a
    /// copy, not a move, and a copy has to be fetched.
    func testACopyIsNotMistakenForARename() {
        let index = [entry("DCIM/Camera/a.jpg", at: 6 * day, sha: "same")]
        let plan = PhotoDelta.plan(
            items: [item("DCIM/Camera/a.jpg", at: 6 * day, sha: "same"),
                    item("DCIM/Camera/b.jpg", at: 6 * day, sha: "same")],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(plan.renames.isEmpty)
        XCTAssertEqual(plan.want.map(\.key), ["DCIM/Camera/b.jpg"])
    }

    // MARK: - The approval gate

    func testFirstRunAlwaysNeedsApprovalEvenForOnePhoto() {
        let plan = PhotoDelta.plan(
            items: [item("one", at: 6 * day)], from: 5 * day, index: [], isFirstRun: true
        )
        XCTAssertEqual(plan.want.count, 1)
        XCTAssertTrue(plan.needsApproval)
        XCTAssertNotNil(plan.approvalReason)
    }

    func testASmallEverydayBatchNeedsNoApproval() {
        let items = (1...20).map { item("k\($0)", at: 6 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ], isFirstRun: false)
        XCTAssertEqual(plan.want.count, 20)
        XCTAssertFalse(plan.needsApproval)
    }

    func testTooManyItemsParkThePlan() {
        let items = (1...250).map { item("k\($0)", at: 6 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ], isFirstRun: false)
        XCTAssertTrue(plan.needsApproval)
    }

    func testTooManyBytesParkThePlan() {
        let items = (1...3).map { item("k\($0)", at: 6 * day, size: 1_000_000_000, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ], isFirstRun: false)
        XCTAssertTrue(plan.needsApproval)
        XCTAssertEqual(plan.wantBytes, 3_000_000_000)
    }

    /// 46 GB from a wide window: parked, and ordered so that approving it brings
    /// this month's photos before 2005's.
    func testAHugeBacklogIsParkedAndOrderedNewestFirst() {
        let items = (1...5000).map { item("k\($0)", at: Int64($0) * day, size: 9_000_000, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 0, index: [], isFirstRun: true)
        XCTAssertTrue(plan.needsApproval)
        XCTAssertEqual(plan.want.first?.key, "k5000")
        XCTAssertEqual(plan.want.last?.key, "k1")
    }

    // MARK: - Hashes

    func testAnAbsentHashFallsBackToSizeAndCaptureTime() {
        let index = [entry("k", at: 6 * day, size: 1_000, sha: "aa")]
        let same = PhotoDelta.plan(
            items: [item("k", at: 6 * day, size: 1_000, sha: nil)],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(same.want.isEmpty)

        let resized = PhotoDelta.plan(
            items: [item("k", at: 6 * day, size: 2_000, sha: nil)],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertEqual(resized.want.count, 1)
    }

    func testAChangedHashIsWanted() {
        let index = [entry("k", at: 6 * day, sha: "before")]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day, sha: "after")],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertEqual(plan.want.map(\.key), ["k"])
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testHashComparisonIgnoresLetterCase() {
        let index = [entry("k", at: 6 * day, sha: "ABC")]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day, sha: "abc")],
            from: 5 * day, index: index, isFirstRun: false
        )
        XCTAssertTrue(plan.want.isEmpty)
    }
}

/// The window is two lower bounds, and which one wins decides whether a wide
/// start date can start a 46 GB import on its own. It cannot.
final class PhotoWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheLaterBoundWins() {
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let from = PhotoWindow.effectiveFrom(startDate: old, lastDays: 30, now: now)
        XCTAssertEqual(from, Int64((now.timeIntervalSince1970 - 30 * 86_400) * 1000))
    }

    func testARecentStartDateBeatsTheDayCount() {
        let recent = now.addingTimeInterval(-86_400)
        let from = PhotoWindow.effectiveFrom(startDate: recent, lastDays: 30, now: now)
        XCTAssertEqual(from, Int64(recent.timeIntervalSince1970 * 1000))
    }

    func testWithoutAStartDateTheDayCountIsTheWholeFuse() {
        let from = PhotoWindow.effectiveFrom(startDate: nil, lastDays: 7, now: now)
        XCTAssertEqual(from, Int64((now.timeIntervalSince1970 - 7 * 86_400) * 1000))
    }

    func testAZeroDayCountIsReadAsOneDayNotAsEverything() {
        let from = PhotoWindow.effectiveFrom(startDate: nil, lastDays: 0, now: now)
        XCTAssertEqual(from, Int64((now.timeIntervalSince1970 - 86_400) * 1000))
    }
}

/// The wire shape, asserted key by key: Swift and Kotlin have to agree, and the
/// single letter keys are what five thousand rows are paying for.
final class PhotoItemCodingTests: XCTestCase {

    func testItemUsesSingleLetterKeys() throws {
        let item = PhotoItem(key: "DCIM/Camera/a.jpg", captureAt: 123, size: 456,
                             mime: "image/jpeg", sha256: "abc", excluded: .size)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(item), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"h":"abc","k":"DCIM\/Camera\/a.jpg","m":"image\/jpeg","s":456,"t":123,"x":"size"}"#
        )
    }

    func testAbsentFieldsStayOutOfTheJSON() throws {
        let item = PhotoItem(key: "k", captureAt: 1, size: 2)
        let json = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertFalse(json.contains("\"h\""))
        XCTAssertFalse(json.contains("\"x\""))
        XCTAssertFalse(json.contains("\"m\""))
    }

    func testItemSurvivesARoundTrip() throws {
        let item = PhotoItem(key: "k", captureAt: 7, size: 8, mime: "video/mp4",
                             sha256: "ff", excluded: .noLocation)
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: try JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
    }

    func testPayloadCarriesOnlyWhatWasSet() throws {
        let payload = PhotoPayload(manifestId: "m1", page: 1, pages: 2, count: 700, from: 99)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        XCTAssertEqual(json, #"{"count":700,"from":99,"manifestId":"m1","page":1,"pages":2}"#)
    }
}
