import XCTest
@testable import MacDroidSyncCore

/// The heart of the auto lock. RSSI is noisy enough that a single reading means
/// nothing, so what is asserted here is the behaviour of the average: a dip does
/// not lock the Mac, a real departure does, and nothing at all happens before the
/// phone has been recognised.
///
/// Time is passed in, so every case below is a synthetic series of readings
/// rather than a wait.
final class PresenceEvaluatorTests: XCTestCase {

    /// Balanced preset with a small window, so the tests stay short.
    private func evaluator() -> PresenceEvaluator {
        PresenceEvaluator(settings: PresenceSettings(
            window: 10,
            awayThreshold: -80,
            nearThreshold: -72,
            lostAfter: 5,
            grace: 10,
            minSamples: 3
        ))
    }

    /// Feeds one reading a second and returns everything that came out of it.
    private func feed(
        _ evaluator: PresenceEvaluator,
        rssi: Int,
        seconds: Int,
        from start: TimeInterval = 0
    ) -> [PresenceEvaluator.Outcome] {
        var outcomes: [PresenceEvaluator.Outcome] = []
        for step in 0 ..< seconds {
            let now = start + TimeInterval(step)
            evaluator.record(rssi: rssi, at: now)
            outcomes.append(evaluator.evaluate(at: now))
        }
        return outcomes
    }

    /// Same, but no reading arrives: the beacon is simply gone.
    private func silence(
        _ evaluator: PresenceEvaluator,
        seconds: Int,
        from start: TimeInterval
    ) -> [PresenceEvaluator.Outcome] {
        (0 ..< seconds).map { evaluator.evaluate(at: start + TimeInterval($0)) }
    }

    func testNothingHappensBeforeThePhoneIsEverSeen() {
        let subject = evaluator()
        let outcomes = silence(subject, seconds: 120, from: 0)

        XCTAssertEqual(subject.state, .unarmed)
        XCTAssertFalse(outcomes.contains(.lock), "an unseen phone must never lock the Mac")
        XCTAssertFalse(outcomes.contains(.leaving))
    }

    func testAStrongPhoneArmsTheFeatureOnce() {
        let subject = evaluator()
        let outcomes = feed(subject, rssi: -55, seconds: 10)

        XCTAssertEqual(outcomes.filter { $0 == .armed }.count, 1)
        XCTAssertEqual(subject.state, .near)
        XCTAssertEqual(subject.mean ?? 0, -55, accuracy: 0.01)
    }

    func testTwoSamplesAreNotEnoughToArm() {
        let subject = evaluator()
        let outcomes = feed(subject, rssi: -50, seconds: 2)

        XCTAssertEqual(outcomes, [.idle, .idle])
        XCTAssertNil(subject.mean, "the mean is withheld below minSamples")
        XCTAssertEqual(subject.state, .unarmed)
    }

    /// The case that motivated the averaging: a hand over the phone, a passing
    /// body, a closing door.
    func testAMomentaryDipDoesNotLock() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)

        var outcomes: [PresenceEvaluator.Outcome] = []
        var now: TimeInterval = 10
        for step in 0 ..< 30 {
            // One reading in five collapses to -95 dBm.
            subject.record(rssi: step % 5 == 0 ? -95 : -55, at: now)
            outcomes.append(subject.evaluate(at: now))
            now += 1
        }

        XCTAssertEqual(subject.state, .near)
        XCTAssertFalse(outcomes.contains(.leaving), "the mean must absorb the dips")
        XCTAssertFalse(outcomes.contains(.lock))
    }

    func testASustainedDropLocksExactlyOnce() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)
        let outcomes = feed(subject, rssi: -88, seconds: 40, from: 10)

        XCTAssertEqual(outcomes.filter { $0 == .leaving }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .lock }.count, 1, "one departure is one lock")
        // Back to unarmed, so the phone has to be seen again before the next one.
        XCTAssertEqual(subject.state, .unarmed)
    }

    /// What the countdown panel on screen reads. It has no clock of its own, so
    /// this is the number the user sees tick down.
    func testTheCountdownRunsForTheWholeGracePeriod() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)
        XCTAssertNil(subject.secondsUntilLock(at: 10), "nothing to count down while the phone is here")

        // Straight to a lost beacon, which is what walking away looks like.
        var now: TimeInterval = 10
        while subject.evaluate(at: now) != .leaving, now < 40 { now += 1 }
        let startedAt = now

        XCTAssertEqual(subject.secondsUntilLock(at: startedAt) ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(subject.secondsUntilLock(at: startedAt + 4) ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(subject.secondsUntilLock(at: startedAt + 9.5) ?? 0, 0.5, accuracy: 0.01)
        // Never negative: the panel would otherwise show a minus sign.
        XCTAssertEqual(subject.secondsUntilLock(at: startedAt + 30) ?? -1, 0, accuracy: 0.01)

        XCTAssertEqual(subject.evaluate(at: startedAt + 10), .lock)
        XCTAssertNil(subject.secondsUntilLock(at: startedAt + 10), "the countdown is over once it locked")
    }

    func testTheCountdownStopsWhenThePhoneComesBack() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)
        var now: TimeInterval = 10
        while subject.evaluate(at: now) != .leaving, now < 40 { now += 1 }
        XCTAssertNotNil(subject.secondsUntilLock(at: now))

        let back = feed(subject, rssi: -50, seconds: 20, from: now + 1)
        XCTAssertTrue(back.contains(.returned))
        XCTAssertNil(subject.secondsUntilLock(at: now + 21))
    }

    /// Walking out of range is what this really looks like: the packets stop.
    func testAVanishedBeaconLocks() {
        let subject = evaluator()
        _ = feed(subject, rssi: -60, seconds: 10)
        let outcomes = silence(subject, seconds: 40, from: 10)

        XCTAssertEqual(outcomes.filter { $0 == .lock }.count, 1)
        // The samples still inside the window must not read as "it is back".
        XCTAssertFalse(outcomes.contains(.returned))
    }

    func testComingBackDuringTheGracePeriodCancelsTheLock() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)

        var now: TimeInterval = 10
        var leavingAt: TimeInterval?
        while now < 40, leavingAt == nil {
            subject.record(rssi: -88, at: now)
            if subject.evaluate(at: now) == .leaving { leavingAt = now }
            now += 1
        }
        XCTAssertNotNil(leavingAt)

        let back = feed(subject, rssi: -50, seconds: 20, from: now)
        XCTAssertTrue(back.contains(.returned))
        XCTAssertFalse(back.contains(.lock))
        XCTAssertEqual(subject.state, .near)
    }

    /// The averaging costs time on purpose: a strong signal that collapses does
    /// not start the countdown until the window has actually filled with weak
    /// readings. That inertia is what makes a dip harmless, and it is why the
    /// lock lands well after the grace period alone would suggest.
    func testTheAverageAddsDeliberateInertia() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)

        let immediate = feed(subject, rssi: -88, seconds: 3, from: 10)
        XCTAssertFalse(immediate.contains(.leaving), "three weak readings cannot outvote a full window")
        XCTAssertEqual(subject.state, .near)

        let outcomes = feed(subject, rssi: -88, seconds: 30, from: 13)
        XCTAssertTrue(outcomes.contains(.leaving))
        XCTAssertTrue(outcomes.contains(.lock))
    }

    /// A phone sitting right at the edge of the range would flap without the
    /// gap between the two thresholds.
    func testHysteresisKeepsTheStateStillAtTheEdge() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)

        var outcomes: [PresenceEvaluator.Outcome] = []
        var now: TimeInterval = 10
        for step in 0 ..< 60 {
            // Oscillating between the two thresholds: -78 and -74 dBm.
            subject.record(rssi: step.isMultiple(of: 2) ? -78 : -74, at: now)
            outcomes.append(subject.evaluate(at: now))
            now += 1
        }

        XCTAssertEqual(subject.state, .near, "in the dead band the state must not move")
        XCTAssertEqual(outcomes.filter { $0 != .idle }, [])
    }

    func testResetRequiresAFreshSighting() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)
        subject.reset()

        XCTAssertEqual(subject.state, .unarmed)
        XCTAssertNil(subject.mean)
        // Two readings are not enough, the third one arms it again.
        XCTAssertEqual(feed(subject, rssi: -55, seconds: 2, from: 20), [.idle, .idle])
        XCTAssertEqual(feed(subject, rssi: -55, seconds: 1, from: 22), [.armed])
    }

    /// What "Don't lock" does: the countdown is dropped and nothing is locked,
    /// but the moment the phone is visible again the feature goes back to
    /// waiting for the next departure. A fixed pause would either be too short
    /// or leave the Mac unguarded for an hour.
    func testCancellingTheCountdownWaitsForThePhoneToComeBack() {
        let subject = evaluator()
        _ = feed(subject, rssi: -55, seconds: 10)
        var now: TimeInterval = 10
        while subject.evaluate(at: now) != .leaving, now < 40 { now += 1 }

        // The user pressed the button.
        subject.reset()
        XCTAssertEqual(subject.state, .unarmed)

        // However long the phone stays away, nothing is locked.
        let whileAway = silence(subject, seconds: 120, from: now)
        XCTAssertFalse(whileAway.contains(.lock))
        XCTAssertFalse(whileAway.contains(.leaving))

        // It comes back: straight to waiting for the next departure.
        let back = feed(subject, rssi: -55, seconds: 5, from: now + 120)
        XCTAssertTrue(back.contains(.armed))

        // And that departure locks, exactly as it would have before.
        let leaves = silence(subject, seconds: 40, from: now + 125)
        XCTAssertTrue(leaves.contains(.leaving))
        XCTAssertEqual(leaves.filter { $0 == .lock }.count, 1)
    }

    func testImpossibleReadingsAreIgnored() {
        let subject = evaluator()
        // 127 is CoreBluetooth for "unknown", and 0 is not a real reading either.
        for value in [127, 0, -128] {
            subject.record(rssi: value, at: 0)
        }
        XCTAssertEqual(subject.sampleCount, 0)
        XCTAssertNil(subject.mean)
    }

    func testPresetsKeepAGapBetweenTheThresholds() {
        for preset in [PresenceSettings.fast, .balanced, .cautious] {
            XCTAssertGreaterThan(
                preset.nearThreshold,
                preset.awayThreshold,
                "\(preset.presetName ?? "preset") would flap without hysteresis"
            )
            XCTAssertNotNil(preset.presetName)
        }
    }
}
