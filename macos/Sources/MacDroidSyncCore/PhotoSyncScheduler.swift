import Foundation

/// Asks the phone what it has, every so often, and only when asking makes sense.
///
/// Its own type rather than a timer inside the menu controller, because "is a
/// cycle due" has more inputs than it looks - the interval, when the last
/// manifest arrived, when the last one was *asked for*, whether the phone is
/// there at all - and this feature's one lesson is that decisions belong where
/// they can be tested without a clock.
///
/// The pace used to belong to the phone. It belongs here now, with the rest of
/// the settings, which is also why nothing here is written down: `lastCycleAt`
/// already survives restarts in `photos-state.json`, and a second copy of the
/// same fact would be a second chance to disagree.
public final class PhotoSyncScheduler {

    private let tick: TimeInterval
    private let intervalMinutes: () -> Int
    private let isEligible: () -> Bool
    private let lastCycleAt: () -> Int64?
    private let now: () -> Int64
    private let fire: () -> Void

    private var timer: DispatchSourceTimer?
    /// When a manifest was last *asked for*, as opposed to last received.
    ///
    /// Deliberately not persisted. Without it a phone that never answers would
    /// be asked on every tick; with it persisted, a relaunch would wait out the
    /// whole interval before trying again, and one extra ask after a restart is
    /// the friendlier of the two mistakes.
    private var lastAskedAt: Int64?

    public init(
        tick: TimeInterval = 30,
        intervalMinutes: @escaping () -> Int,
        isEligible: @escaping () -> Bool,
        lastCycleAt: @escaping () -> Int64?,
        now: @escaping () -> Int64 = { Message.now() },
        fire: @escaping () -> Void
    ) {
        self.tick = tick
        self.intervalMinutes = intervalMinutes
        self.isEligible = isEligible
        self.lastCycleAt = lastCycleAt
        self.now = now
        self.fire = fire
    }

    deinit { timer?.cancel() }

    /// A fixed tick that asks "is it time yet" rather than a timer set to the
    /// interval: it survives the interval being changed while it runs, and it
    /// does not have to be rearmed after the Mac wakes up.
    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + tick, repeating: tick, leeway: .seconds(15))
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The manual "Sync photos now" went out; the countdown starts again. Without
    /// this, asking by hand and then having the timer fire seconds later would
    /// put two manifests on the wire back to back.
    public func noteAsked() {
        lastAskedAt = now()
    }

    /// The phone came back. Nothing is asked here - a cycle that is due will go
    /// out on the next tick, which gives the configuration sent during the
    /// handshake time to land first.
    public func connected() {
        lastAskedAt = nil
    }

    /// One tick's worth of deciding. Internal so the tests can drive it
    /// without waiting on a real clock.
    func check() {
        guard isEligible() else { return }
        let moment = now()
        guard Self.isDue(
            lastAt: Self.later(lastCycleAt(), lastAskedAt),
            now: moment,
            intervalMinutes: intervalMinutes()
        ) else { return }
        lastAskedAt = moment
        fire()
    }

    /// Whether a cycle is due. Nothing ever having happened counts as due: that
    /// is a fresh install, and its first manifest is what becomes the starting
    /// point.
    static func isDue(lastAt: Int64?, now: Int64, intervalMinutes: Int) -> Bool {
        guard let lastAt, lastAt > 0 else { return true }
        return now - lastAt >= Int64(intervalMinutes) * 60_000
    }

    private static func later(_ first: Int64?, _ second: Int64?) -> Int64? {
        switch (first, second) {
        case (let first?, let second?): return max(first, second)
        default: return first ?? second
        }
    }
}
