import Foundation

/// Tuning of the away detection. The defaults are the "balanced" preset.
public struct PresenceSettings: Equatable {
    /// How much history the average is taken over.
    public var window: TimeInterval
    /// Mean RSSI below which the phone counts as leaving.
    public var awayThreshold: Double
    /// Mean RSSI needed to count as present again. Higher than `awayThreshold`
    /// on purpose: without that gap the state would flap on the edge of range.
    public var nearThreshold: Double
    /// No packet at all for this long means the phone is out of range. Walking
    /// away rarely produces a gentle slope - the beacon simply stops arriving.
    public var lostAfter: TimeInterval
    /// How long the "leaving" condition has to hold before the Mac locks.
    public var grace: TimeInterval
    /// Fewer samples than this in the window is no basis for any verdict.
    public var minSamples: Int

    public init(
        window: TimeInterval = 20,
        awayThreshold: Double = -80,
        nearThreshold: Double = -72,
        lostAfter: TimeInterval = 15,
        grace: TimeInterval = 20,
        minSamples: Int = 3
    ) {
        self.window = window
        self.awayThreshold = awayThreshold
        self.nearThreshold = nearThreshold
        self.lostAfter = lostAfter
        self.grace = grace
        self.minSamples = minSamples
    }

    /// `lostAfter` is not scaled down with the rest: macOS delivers the beacon
    /// in bursts with quiet spells of up to about seven seconds even with the
    /// phone on the desk, so anything much below fifteen seconds would call a
    /// present phone lost. See the measurement in README.
    public static let fast = PresenceSettings(
        window: 10, awayThreshold: -75, nearThreshold: -68, lostAfter: 15, grace: 10
    )
    public static let balanced = PresenceSettings()
    public static let cautious = PresenceSettings(
        window: 30, awayThreshold: -85, nearThreshold: -78, lostAfter: 30, grace: 45
    )

    /// Name of the matching preset, or nil once the thresholds were edited.
    public var presetName: String? {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .cautious: return "Cautious"
        default: return nil
        }
    }
}

public enum PresenceState: String {
    /// The phone has not been recognised yet, so nothing will be locked. This is
    /// where the state machine starts and where it returns after a lock.
    case unarmed
    case near
    case leaving
}

/// Turns a stream of RSSI readings into a lock decision.
///
/// RSSI is noisy: a hand over the phone, a passing body or a wall costs 10 to 15
/// dB in an instant. A single reading therefore means nothing, and every verdict
/// here is taken from the **mean over a time window**, guarded by hysteresis and
/// by a grace period.
///
/// There is no Bluetooth and no wall clock in this type: the caller passes the
/// time in, which is what makes the behaviour testable with a synthetic series.
public final class PresenceEvaluator {
    public enum Outcome: Equatable {
        case idle
        /// The phone was recognised; from now on a departure can lock the Mac.
        case armed
        /// It came back before the grace period was over.
        case returned
        /// The grace period just started; the countdown is now running.
        case leaving
        case lock
    }

    public var settings: PresenceSettings
    public private(set) var state: PresenceState = .unarmed

    private var samples: [(at: TimeInterval, rssi: Double)] = []
    private var lastSeen: TimeInterval?
    private var leavingSince: TimeInterval?

    public init(settings: PresenceSettings = .balanced) {
        self.settings = settings
    }

    // MARK: - Readings

    public func record(rssi: Int, at now: TimeInterval) {
        // A radio that reports 127 (or 0) means "unknown", not "very strong".
        guard rssi < 0, rssi > -128 else { return }
        samples.append((at: now, rssi: Double(rssi)))
        lastSeen = now
        prune(before: now - settings.window)
    }

    /// Mean RSSI of the window, nil while there is not enough of it.
    public var mean: Double? {
        guard samples.count >= settings.minSamples else { return nil }
        return samples.reduce(0) { $0 + $1.rssi } / Double(samples.count)
    }

    public var sampleCount: Int { samples.count }

    public func secondsSinceLastSample(at now: TimeInterval) -> TimeInterval? {
        guard let lastSeen else { return nil }
        return now - lastSeen
    }

    /// Time left before the screen is locked, nil unless the countdown is
    /// running. The single source of truth for the on screen counter: nothing
    /// else keeps a clock of its own, so what the user reads cannot drift away
    /// from what actually decides.
    public func secondsUntilLock(at now: TimeInterval) -> TimeInterval? {
        guard state == .leaving, let leavingSince else { return nil }
        return max(0, settings.grace - (now - leavingSince))
    }

    // MARK: - Decision

    public func evaluate(at now: TimeInterval) -> Outcome {
        prune(before: now - settings.window)
        let average = mean
        let lost = isLost(at: now)

        switch state {
        case .unarmed:
            guard !lost, let average, average >= settings.nearThreshold else { return .idle }
            state = .near
            return .armed

        case .near:
            let tooWeak = average.map { $0 < settings.awayThreshold } ?? false
            guard lost || tooWeak else { return .idle }
            state = .leaving
            leavingSince = now
            return .leaving

        case .leaving:
            if !lost, let average, average >= settings.nearThreshold {
                state = .near
                leavingSince = nil
                return .returned
            }
            if now - (leavingSince ?? now) >= settings.grace {
                reset()
                return .lock
            }
            return .idle
        }
    }

    /// Back to square one: used after a lock, when the phone asks for the
    /// feature to be off, and whenever scanning stops. The samples go away too,
    /// so re-arming needs a fresh sighting rather than stale history.
    public func reset() {
        state = .unarmed
        samples.removeAll()
        lastSeen = nil
        leavingSince = nil
    }

    private func isLost(at now: TimeInterval) -> Bool {
        guard let lastSeen else { return true }
        return now - lastSeen > settings.lostAfter
    }

    private func prune(before cutoff: TimeInterval) {
        guard let first = samples.first, first.at < cutoff else { return }
        samples.removeAll { $0.at < cutoff }
    }
}
