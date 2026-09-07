import XCTest
@testable import MacDroidSyncCore

/// The question this file answers: can a stored value - typed, migrated, or put
/// there by `defaults write` - make this Mac ask the phone for something it
/// should never ask for?
final class PhotoSyncSettingsTests: XCTestCase {

    /// `UserDefaults.integer` returns 0 for a key that was never written, and it
    /// cannot tell that from a real zero. Zero is not a sane value for any of
    /// these, so it has to read as the default rather than as "nothing".
    func testAnAbsentSettingReadsAsItsDefault() {
        XCTAssertEqual(PhotoSyncSettings.days(from: 0), PhotoSyncSettings.defaultDays)
        XCTAssertEqual(
            PhotoSyncSettings.intervalMinutes(from: 0),
            PhotoSyncSettings.defaultIntervalMinutes
        )
        XCTAssertEqual(PhotoSyncSettings.maxItemMB(from: 0), PhotoSyncSettings.defaultMaxItemMB)
    }

    func testAValueOutsideTheRangeIsBroughtBack() {
        XCTAssertEqual(PhotoSyncSettings.days(from: -5), PhotoSyncSettings.days.lowerBound)
        XCTAssertEqual(PhotoSyncSettings.days(from: 99_999), PhotoSyncSettings.days.upperBound)
        XCTAssertEqual(
            PhotoSyncSettings.intervalMinutes(from: 1),
            PhotoSyncSettings.intervalMinutes.lowerBound
        )
        XCTAssertEqual(
            PhotoSyncSettings.intervalMinutes(from: 9_999),
            PhotoSyncSettings.intervalMinutes.upperBound
        )
        XCTAssertEqual(
            PhotoSyncSettings.maxItemMB(from: 999_999),
            PhotoSyncSettings.maxItemMB.upperBound
        )
    }

    func testAValueInsideTheRangeIsLeftAlone() {
        XCTAssertEqual(PhotoSyncSettings.days(from: 45), 45)
        XCTAssertEqual(PhotoSyncSettings.intervalMinutes(from: 5), 5)
        XCTAssertEqual(PhotoSyncSettings.maxItemMB(from: 512), 512)
    }

    /// A blank album name has one obvious reading, so it takes it rather than
    /// refusing to save.
    func testABlankAlbumNameIsTheDefault() {
        XCTAssertEqual(PhotoSyncSettings.albumName(from: nil), PhotoSyncSettings.defaultAlbumName)
        XCTAssertEqual(PhotoSyncSettings.albumName(from: ""), PhotoSyncSettings.defaultAlbumName)
        XCTAssertEqual(PhotoSyncSettings.albumName(from: "   "), PhotoSyncSettings.defaultAlbumName)
        XCTAssertEqual(PhotoSyncSettings.albumName(from: "  Phone  "), "Phone")
    }
}

/// The question this file answers: does the Mac ask the phone for a manifest
/// when it should, and stay quiet when it should not?
final class PhotoSyncSchedulerTests: XCTestCase {

    private let minute: Int64 = 60_000

    func testNothingHasHappenedYetSoACycleIsDue() {
        XCTAssertTrue(PhotoSyncScheduler.isDue(lastAt: nil, now: 1_000, intervalMinutes: 30))
        XCTAssertTrue(PhotoSyncScheduler.isDue(lastAt: 0, now: 1_000, intervalMinutes: 30))
    }

    func testACycleIsDueOnceTheIntervalHasPassed() {
        let start: Int64 = 1_000_000
        XCTAssertFalse(
            PhotoSyncScheduler.isDue(lastAt: start, now: start + 29 * minute, intervalMinutes: 30)
        )
        XCTAssertTrue(
            PhotoSyncScheduler.isDue(lastAt: start, now: start + 30 * minute, intervalMinutes: 30)
        )
    }

    func testNothingIsAskedWhileThePhoneIsNotThere() {
        var asked = 0
        var connected = false
        let scheduler = PhotoSyncScheduler(
            intervalMinutes: { 30 },
            isEligible: { connected },
            lastCycleAt: { nil },
            now: { 10 * self.minute },
            fire: { asked += 1 }
        )
        scheduler.check()
        XCTAssertEqual(asked, 0, "a cycle that cannot be answered is not worth asking")

        connected = true
        scheduler.check()
        XCTAssertEqual(asked, 1)
    }

    /// Asking by hand and then having the timer fire moments later would put two
    /// manifests on the wire back to back.
    func testASyncNowRestartsTheCountdown() {
        var asked = 0
        var moment: Int64 = 10 * minute
        let scheduler = PhotoSyncScheduler(
            intervalMinutes: { 30 },
            isEligible: { true },
            lastCycleAt: { nil },
            now: { moment },
            fire: { asked += 1 }
        )
        scheduler.noteAsked()
        moment += 20 * minute
        scheduler.check()
        XCTAssertEqual(asked, 0)

        moment += 11 * minute
        scheduler.check()
        XCTAssertEqual(asked, 1)
    }

    /// The countdown lives in the state file, so a relaunch does not mean a
    /// fresh manifest every time the app starts.
    func testTheCountdownSurvivesARestart() {
        var asked = 0
        let last: Int64 = 100 * minute
        let scheduler = PhotoSyncScheduler(
            intervalMinutes: { 30 },
            isEligible: { true },
            lastCycleAt: { last },
            now: { last + 5 * self.minute },
            fire: { asked += 1 }
        )
        scheduler.check()
        XCTAssertEqual(asked, 0, "five minutes after the last cycle is not due")
    }

    /// A fresh install is due at once, and that first manifest is what becomes
    /// the starting point.
    func testAFreshInstallIsDueAsSoonAsThePhoneConnects() {
        var asked = 0
        let scheduler = PhotoSyncScheduler(
            intervalMinutes: { 30 },
            isEligible: { true },
            lastCycleAt: { nil },
            now: { 1_000 },
            fire: { asked += 1 }
        )
        scheduler.connected()
        scheduler.check()
        XCTAssertEqual(asked, 1)
    }
}
