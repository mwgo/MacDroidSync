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
        state: PhotoIndexState = .imported,
        ignoredVersion: String? = nil
    ) -> PhotoIndexEntry {
        PhotoIndexEntry(key: key, sha256: sha, size: size, captureAt: captureAt,
                        localIdentifier: "asset/\(key)", state: state, importedAt: 1,
                        ignoredVersion: ignoredVersion)
    }

    // MARK: - Deleting

    /// A complete, honest manifest that happens to be empty must not be read as
    /// "the user deleted everything".
    func testEmptyButCompleteManifestRefusesToDeleteTheLibrary() {
        let index = (1...300).map { entry("k\($0)", at: 5 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: [], from: day, index: index)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertEqual(plan.refusedDelete.count, 300)
    }

    /// Twenty vanished photos out of three hundred is plausible tidying, so it
    /// goes through; the guard is for the runaway case.
    func testASmallDisappearanceIsDeletedNormally() {
        var index = (1...300).map { entry("k\($0)", at: 5 * day, sha: "h\($0)") }
        let items = index.dropFirst(15).map { item($0.key, at: $0.captureAt, sha: $0.sha256) }
        index = Array(index)
        let plan = PhotoDelta.plan(items: items, from: day, index: index)
        XCTAssertEqual(plan.delete.count, 15)
        XCTAssertTrue(plan.refusedDelete.isEmpty)
    }

    /// The rule the whole design rests on: a photo that fell out of the window is
    /// not a deletion, because the Mac only ever judges what the phone declared.
    func testAgedOutEntryIsNotDeleted() {
        let index = [entry("old", at: 1 * day), entry("new", at: 10 * day)]
        let plan = PhotoDelta.plan(
            items: [item("new", at: 10 * day)], from: 5 * day, index: index
        )
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.refusedDelete.isEmpty)
    }

    /// And the reason tombstones exist: without them, deleting last year's photo
    /// on the phone could never reach the Mac, because it is outside the window.
    func testTombstoneDeletesOutsideTheWindow() {
        let index = [entry("old", at: 1 * day)]
        let plan = PhotoDelta.plan(
            items: [], from: 5 * day, tombstones: ["old"], index: index
        )
        XCTAssertEqual(plan.delete.map(\.key), ["old"])
    }

    /// A video the phone refuses to send is listed, not omitted - otherwise it
    /// would look exactly like a deletion.
    func testExcludedItemIsNeitherWantedNorDeleted() {
        let index = [entry("clip.mp4", at: 6 * day)]
        let plan = PhotoDelta.plan(
            items: [item("clip.mp4", at: 6 * day, size: 3_000_000_000, excluded: .size)],
            from: 5 * day, index: index
        )
        XCTAssertTrue(plan.want.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertEqual(plan.excluded.map(\.key), ["clip.mp4"])
    }

    // MARK: - Not coming back

    func testWhatTheUserDeletedInPhotosIsNotImportedAgain() {
        let index = [entry("gone", at: 6 * day, state: .removedByUser)]
        let plan = PhotoDelta.plan(
            items: [item("gone", at: 6 * day)], from: 5 * day, index: index
        )
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// Even edited on the phone: new bytes are still the photo the user threw
    /// away here, and the Mac's decision outranks the phone's.
    func testAnEditedPhotoTheUserDeletedStillDoesNotComeBack() {
        let index = [entry("gone", at: 6 * day, sha: "old", state: .removedByUser)]
        let plan = PhotoDelta.plan(
            items: [item("gone", at: 6 * day, sha: "new")], from: 5 * day, index: index
        )
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// The other side of that coin, and the reason `deletedByUs` is a separate
    /// state: we removed it because the phone had, so when the phone has it
    /// again it is welcome back. Nobody rejected it here.
    func testAPhotoWeRemovedComesBackWhenThePhoneHasItAgain() {
        let index = [entry("k", at: 6 * day, state: .deletedByUs)]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day)], from: 5 * day, index: index
        )
        XCTAssertEqual(plan.want.map(\.key), ["k"])
    }

    func testRestoredFromTheBinCancelsThePendingDeletion() {
        let index = [entry("back", at: 6 * day, sha: "same", state: .pendingDelete)]
        let plan = PhotoDelta.plan(
            items: [item("back", at: 6 * day, sha: "same")], from: 5 * day, index: index
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
            from: 5 * day, index: index
        )
        XCTAssertEqual(plan.renames, [PhotoRename(from: "DCIM/Camera/a.jpg", to: "DCIM/Camera/b.jpg")])
        XCTAssertTrue(plan.want.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testASmallEverydayBatchNeedsNoApproval() {
        let items = (1...20).map { item("k\($0)", at: 6 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ])
        XCTAssertEqual(plan.want.count, 20)
        XCTAssertFalse(plan.needsApproval)
    }

    func testTooManyItemsParkThePlan() {
        let items = (1...250).map { item("k\($0)", at: 6 * day, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ])
        XCTAssertTrue(plan.needsApproval)
    }

    func testTooManyBytesParkThePlan() {
        let items = (1...3).map { item("k\($0)", at: 6 * day, size: 1_000_000_000, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 5 * day, index: [
            entry("seen", at: 6 * day)
        ])
        XCTAssertTrue(plan.needsApproval)
        XCTAssertEqual(plan.wantBytes, 3_000_000_000)
    }

    /// 46 GB from a wide window: parked, and ordered so that approving it brings
    /// this month's photos before 2005's.
    func testAHugeBacklogIsParkedAndOrderedNewestFirst() {
        let items = (1...5000).map { item("k\($0)", at: Int64($0) * day, size: 9_000_000, sha: "h\($0)") }
        let plan = PhotoDelta.plan(items: items, from: 0, index: [])
        XCTAssertTrue(plan.needsApproval)
        XCTAssertEqual(plan.want.first?.key, "k5000")
        XCTAssertEqual(plan.want.last?.key, "k1")
    }

    // MARK: - Hashes

    func testAnAbsentHashFallsBackToSizeAndCaptureTime() {
        let index = [entry("k", at: 6 * day, size: 1_000, sha: "aa")]
        let same = PhotoDelta.plan(
            items: [item("k", at: 6 * day, size: 1_000, sha: nil)],
            from: 5 * day, index: index
        )
        XCTAssertTrue(same.want.isEmpty)

        let resized = PhotoDelta.plan(
            items: [item("k", at: 6 * day, size: 2_000, sha: nil)],
            from: 5 * day, index: index
        )
        XCTAssertEqual(resized.want.count, 1)
    }

    func testAChangedHashIsWanted() {
        let index = [entry("k", at: 6 * day, sha: "before")]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day, sha: "after")],
            from: 5 * day, index: index
        )
        XCTAssertEqual(plan.want.map(\.key), ["k"])
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testHashComparisonIgnoresLetterCase() {
        let index = [entry("k", at: 6 * day, sha: "ABC")]
        let plan = PhotoDelta.plan(
            items: [item("k", at: 6 * day, sha: "abc")],
            from: 5 * day, index: index
        )
        XCTAssertTrue(plan.want.isEmpty)
    }


    // MARK: - The starting point

    /// A row from the starting point is a note that the phone had it, not a
    /// photo this Mac holds - so only a later edit of it is work.
    func testAPreexistingKeyIsWantedOnlyWhenItsBytesChange() {
        let index = [entry("a", at: 5 * day, sha: "held", state: .preexisting)]
        let same = PhotoDelta.plan(items: [item("a", at: 5 * day, sha: "held")], from: 0,
                                   index: index)
        XCTAssertTrue(same.want.isEmpty)

        let edited = PhotoDelta.plan(items: [item("a", at: 5 * day, sha: "edited")], from: 0,
                                     index: index)
        XCTAssertEqual(edited.want.map(\.key), ["a"])
    }

    /// The point of the whole thing: there is nothing here to remove, so its
    /// disappearance is not a removal to confirm.
    func testAPreexistingKeyIsNeverADeletionCandidate() {
        let index = [entry("a", at: 5 * day, state: .preexisting)]
        let plan = PhotoDelta.plan(items: [], from: 0, index: index)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.refusedDelete.isEmpty)
    }

    /// Without this one video the phone will never send would be reported as a
    /// problem on every cycle, for ever.
    func testAnExcludedPreexistingItemIsNotReportedAgain() {
        let index = [entry("clip.mp4", at: 5 * day, state: .preexisting)]
        let plan = PhotoDelta.plan(items: [item("clip.mp4", at: 5 * day, excluded: .size)],
                                   from: 0, index: index)
        XCTAssertTrue(plan.excluded.isEmpty)
    }

    func testAPreexistingRowSurvivesARoundTrip() throws {
        let row = entry("a", at: 5 * day, state: .preexisting)
        let decoded = try JSONDecoder().decode(
            PhotoIndexEntry.self, from: try JSONEncoder().encode(row)
        )
        XCTAssertEqual(decoded.state, .preexisting)
        XCTAssertTrue(decoded.state.isSettled)
    }

    // MARK: - Rows for the sync window

    /// `want` mixes two questions, and the window has to tell them apart: a key
    /// this Mac has never held is an arrival, the same key with other bytes is a
    /// replacement, and the two deserve different words.
    func testRowsSeparateArrivalsFromReplacements() {
        let index = [entry("held", at: 5 * day, sha: "old"),
                     entry("gone-here", at: 5 * day, state: .deletedByUs)]
        let plan = PhotoDelta.plan(
            items: [item("held", at: 5 * day, sha: "new"), item("fresh", at: 6 * day),
                    item("gone-here", at: 5 * day, sha: "bb"),
                    item("odd", at: 6 * day, excluded: .noDate)],
            from: 0, index: index
        )
        let rows = plan.pendingActions(index: index, now: 42)
        XCTAssertEqual(rows.filter { $0.kind == .change }.map(\.key), ["held"])
        XCTAssertEqual(rows.filter { $0.kind == .add }.map(\.key).sorted(), ["fresh", "gone-here"])
        XCTAssertEqual(rows.filter { $0.kind == .problem }.map(\.key), ["odd"])
        XCTAssertEqual(rows.first?.kind, .problem, "what needs attention sorts to the top")
    }

    func testADeletionRowCarriesWhatTheIndexKnows() {
        let index = [entry("gone", at: 5 * day)]
        let plan = PhotoDelta.plan(items: [], from: 0, index: index)
        let rows = plan.pendingActions(index: index, now: 42)
        XCTAssertEqual(rows.map(\.kind), [.delete])
        XCTAssertEqual(rows.first?.name, "gone")
        XCTAssertNil(rows.first?.item, "there is no manifest item for something that left the phone")
    }

    /// A replaced version is tracked under a synthetic key; the operator should
    /// still read the file's own name.
    func testAReplacedVersionIsNamedAfterItsFile() {
        XCTAssertEqual(
            PhotoPendingAction.name(of: "DCIM/Camera/a.jpg#replaced-1730000000000"),
            "a.jpg"
        )
    }

    // MARK: - What may run without asking

    func testOnlyAdditionsCountsRenamesAndRestoresAsFree() {
        let index = [entry("moved", at: 5 * day, sha: "same"),
                     entry("back", at: 5 * day, sha: "bb", state: .pendingDelete)]
        let plan = PhotoDelta.plan(
            items: [item("elsewhere", at: 5 * day, sha: "same"),
                    item("back", at: 5 * day, sha: "bb"),
                    item("new", at: 6 * day, sha: "cc")],
            from: 0, index: index
        )
        XCTAssertEqual(plan.renames.map(\.to), ["elsewhere"])
        XCTAssertEqual(plan.cancelPendingDelete, ["back"])
        XCTAssertTrue(plan.isAdditionsOnly(index: index),
                      "a rename moves no bytes and a restore deletes nothing")
    }

    func testAChangeOrADeletionOrAProblemIsNotAdditionsOnly() {
        let held = [entry("held", at: 5 * day, sha: "old")]
        let changed = PhotoDelta.plan(items: [item("held", at: 5 * day, sha: "new")], from: 0,
                                      index: held)
        XCTAssertFalse(changed.isAdditionsOnly(index: held))

        let deleted = PhotoDelta.plan(items: [], from: 0, index: held)
        XCTAssertFalse(deleted.isAdditionsOnly(index: held))

        let refused = PhotoDelta.plan(items: [item("odd", at: 5 * day, excluded: .size)], from: 0,
                                      index: [])
        XCTAssertFalse(refused.isAdditionsOnly(index: []))

        let plain = PhotoDelta.plan(items: [item("new", at: 5 * day)], from: 0, index: [])
        XCTAssertTrue(plain.isAdditionsOnly(index: []))
    }

    // MARK: - What the operator refused

    func testAnIgnoredKeyIsNeverWantedAgain() {
        let index = [entry("no", at: 5 * day, state: .ignoredByUser)]
        let plan = PhotoDelta.plan(items: [item("no", at: 5 * day, sha: "anything")], from: 0,
                                   index: index)
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// Ignoring an edit refuses that version, not the photo: a later, different
    /// edit is a question nobody has answered yet.
    func testAnIgnoredVersionIsRefusedButALaterEditIsNot() {
        let index = [entry("a", at: 5 * day, sha: "held", ignoredVersion: "edit-1")]
        let same = PhotoDelta.plan(items: [item("a", at: 5 * day, sha: "edit-1")], from: 0,
                                   index: index)
        XCTAssertTrue(same.want.isEmpty)

        let later = PhotoDelta.plan(items: [item("a", at: 5 * day, sha: "edit-2")], from: 0,
                                    index: index)
        XCTAssertEqual(later.want.map(\.key), ["a"])
    }

    /// The phone is allowed to run out of hashing budget, and then size and
    /// capture time are what decide - so that is what an ignore has to record,
    /// or the refused edit would be back on the next cycle.
    func testAVersionWithNoHashIsStillRecognised() {
        let unhashed = item("a", at: 5 * day, sha: nil)
        let index = [entry("a", at: 5 * day, sha: "held",
                           ignoredVersion: PhotoIndexEntry.fingerprint(of: unhashed))]
        let plan = PhotoDelta.plan(items: [unhashed], from: 0, index: index)
        XCTAssertTrue(plan.want.isEmpty)
    }

    /// And a photo the operator already refused stops being listed as a problem,
    /// which is what stops it parking every cycle for ever.
    func testAnIgnoredProblemIsNotReportedAgain() {
        let index = [entry("odd", at: 5 * day, state: .ignoredByUser)]
        let plan = PhotoDelta.plan(items: [item("odd", at: 5 * day, excluded: .noLocation)],
                                   from: 0, index: index)
        XCTAssertTrue(plan.excluded.isEmpty)
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

    /// The mirror of `PhotoConfigTest` on the phone: two hand written encoders
    /// have to agree on these names or the settings simply never arrive.
    func testTheConfigurationKeysAreTheOnesThePhoneReads() throws {
        let payload = PhotoPayload(enabled: true, lastDays: 30, maxItemBytes: 2_147_483_648)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        XCTAssertEqual(json, #"{"enabled":true,"lastDays":30,"maxItemBytes":2147483648}"#)
    }
}
