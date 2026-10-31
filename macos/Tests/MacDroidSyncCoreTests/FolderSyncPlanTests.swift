import XCTest
@testable import MacDroidSyncCore

final class FolderSyncPlanTests: XCTestCase {

    private func file(_ path: String, _ sha: String) -> FolderEntry { FolderEntry(p: path, s: 1, m: 0, h: sha) }
    private func dir(_ path: String) -> FolderEntry { FolderEntry(p: path, d: true) }
    private func base(_ items: [(String, String?)]) -> [String: FolderBase] {
        Dictionary(uniqueKeysWithValues: items.map { (FolderRules.key($0.0), FolderBase(path: $0.0, sha: $0.1)) })
    }

    func testFirstSyncCopiesBothWaysAndDeletesNothing() {
        let plan = FolderSyncPlan.plan(
            base: [:],
            phone: [file("a.md", "1"), file("same.md", "s"), file("both.md", "p")],
            mac: [file("b.md", "2"), file("same.md", "s"), file("both.md", "m")]
        )
        XCTAssertEqual(Set(plan.steps), [.toMac("a.md"), .toPhone("b.md"), .same("same.md"), .conflict("both.md")])
    }

    func testOneSideChanged() {
        let plan = FolderSyncPlan.plan(
            base: base([("a.md", "1"), ("b.md", "2"), ("c.md", "3")]),
            phone: [file("a.md", "1x"), file("b.md", "2"), file("c.md", "3")],
            mac: [file("a.md", "1"), file("b.md", "2x"), file("c.md", "3")]
        )
        XCTAssertEqual(plan.steps, [.toMac("a.md"), .toPhone("b.md")])
    }

    func testChangedOnBothSides() {
        let plan = FolderSyncPlan.plan(
            base: base([("a.md", "1"), ("b.md", "2")]),
            phone: [file("a.md", "p"), file("b.md", "same")],
            mac: [file("a.md", "m"), file("b.md", "same")]
        )
        XCTAssertEqual(plan.steps, [.conflict("a.md"), .same("b.md")])
    }

    func testDeletionAgainstChange() {
        let plan = FolderSyncPlan.plan(
            base: base([("a.md", "1"), ("b.md", "2"), ("c.md", "3"), ("d.md", "4")]),
            phone: [file("b.md", "2x"), file("c.md", "3"), file("d.md", "4")],
            mac: [file("a.md", "1x"), file("c.md", "3")]
        )
        XCTAssertEqual(Set(plan.steps), [.restoreOnPhone("a.md"), .restoreOnMac("b.md"), .deleteOnPhone("d.md")])
    }

    func testMoveIsNotSentAgain() {
        let plan = FolderSyncPlan.plan(
            base: base([("Notes", nil), ("Notes/Old.md", "1"), ("Notes/Old.assets", nil), ("Notes/Old.assets/x.jpg", "2"), ("k.md", "k")]),
            phone: [dir("Notes"), file("Notes/New.md", "1"), dir("Notes/New.assets"), file("Notes/New.assets/x.jpg", "2"), file("k.md", "k")],
            mac: [dir("Notes"), file("Notes/Old.md", "1"), dir("Notes/Old.assets"), file("Notes/Old.assets/x.jpg", "2"), file("k.md", "k")]
        )
        XCTAssertEqual(plan.steps, [
            .makeDirOnMac("notes/new.assets"),
            .moveOnMac(from: "notes/old.assets/x.jpg", to: "notes/new.assets/x.jpg"),
            .moveOnMac(from: "notes/old.md", to: "notes/new.md"),
            .removeDirOnMac("notes/old.assets"),
        ])
    }

    func testTooManyDeletionsWait() {
        let names = (0..<10).map { "f\($0).txt" }
        let plan = FolderSyncPlan.plan(
            base: base(names.map { ($0, $0) }),
            phone: [file("f0.txt", "f0.txt")],
            mac: names.map { file($0, $0) }
        )
        XCTAssertEqual(plan.heldDeletions, 9)
        XCTAssertEqual(plan.steps, [])
        let allowed = FolderSyncPlan.plan(
            base: base(names.map { ($0, $0) }),
            phone: [file("f0.txt", "f0.txt")],
            mac: names.map { file($0, $0) },
            allowDeletions: true
        )
        XCTAssertEqual(allowed.steps.count, 9)
    }

    func testEmptyPhoneIsNotEverythingDeleted() {
        let plan = FolderSyncPlan.plan(base: base([("a.md", "1")]), phone: [], mac: [file("a.md", "1")])
        XCTAssertEqual(plan.blocked, .phoneEmpty)
        XCTAssertEqual(plan.steps, [])
    }

    func testPendingIsLeftAlone() {
        let plan = FolderSyncPlan.plan(
            base: base([("a.md", "1"), ("b.md", "2")]),
            phone: [file("a.md", "1"), file("b.md", "2")],
            mac: [file("b.md", "2")],
            pending: ["a.md"]
        )
        XCTAssertEqual(plan.steps, [])
    }

    func testMoveOnICloudDriveIsMovedAtOnce() {
        let plan = FolderSyncPlan.plan(
            base: base([("Notes", nil), ("Notes/a.md", "1"), ("Notes/b.md", "2")]),
            phone: [dir("Notes"), file("Notes/a.md", "1"), file("Notes/b.md", "2")],
            mac: [dir("Notes"), dir("Trash"), file("Trash/a.md", "1"), file("Notes/b.md", "2")],
            pending: ["notes/a.md"],
            settling: ["notes/a.md"]
        )
        XCTAssertEqual(plan.steps, [.makeDirOnPhone("trash"), .moveOnPhone(from: "notes/a.md", to: "trash/a.md")])
    }

    func testFolderWaitsForWhatIsLeftForLater() {
        let plan = FolderSyncPlan.plan(
            base: base([("Gone", nil), ("Gone/a.png", "1"), ("k.md", "k")]),
            phone: [dir("Gone"), file("Gone/a.png", "1"), file("k.md", "k")],
            mac: [file("k.md", "k")],
            pending: ["gone/a.png"],
            settling: ["gone/a.png"]
        )
        XCTAssertEqual(plan.steps, [])
    }

    func testCaseAndCompositionMakeOneKey() {
        let decomposed = "Zaz\u{0301}o\u{0301}łc.md".decomposedStringWithCanonicalMapping
        let plan = FolderSyncPlan.plan(
            base: [:],
            phone: [file("Notes/Zaźółc.md", "1")],
            mac: [file("notes/" + decomposed, "1")]
        )
        XCTAssertEqual(plan.steps.count, 1)
        if case .same = plan.steps[0] {} else { XCTFail("\(plan.steps)") }
    }

    func testFoldersMadeAndRemoved() {
        let plan = FolderSyncPlan.plan(
            base: base([("Gone", nil), ("Gone/Deep", nil), ("k.md", "k")]),
            phone: [dir("New"), dir("New/Inner"), file("k.md", "k")],
            mac: [dir("Gone"), dir("Gone/Deep"), file("k.md", "k")]
        )
        XCTAssertEqual(plan.steps, [
            .makeDirOnMac("new"), .makeDirOnMac("new/inner"),
            .removeDirOnMac("gone/deep"), .removeDirOnMac("gone"),
        ])
    }

    func testRules() {
        XCTAssertTrue(FolderRules.isValid(path: "Notes/.notesmd/devices/a.json"))
        XCTAssertFalse(FolderRules.isValid(path: "../x"))
        XCTAssertFalse(FolderRules.isValid(path: "/abs"))
        XCTAssertFalse(FolderRules.isValid(path: "a/.DS_Store"))
        XCTAssertFalse(FolderRules.isValid(path: ".macdroidsync/trash/x"))
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 11; components.hour = 14; components.minute = 5
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(FolderRules.conflictPath("Notes/Plan.md", date: date), "Notes/Plan (Android, Oct 11 14.05).md")
        XCTAssertEqual(FolderRules.conflictPath("Makefile", date: date), "Makefile (Android, Oct 11 14.05)")
    }
}
