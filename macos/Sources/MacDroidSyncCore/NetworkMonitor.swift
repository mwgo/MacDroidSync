import Foundation

/// Watches which Wi-Fi network this Mac is on.
///
/// It polls, the way `PowerMonitor` polls the lid. One mechanism is easier to
/// trust than a notification plus a fallback, the read is a single lookup in the
/// system configuration store, and the resolution does not matter here: the auto
/// lock waits twenty seconds before it does anything, so noticing a changed
/// network a few seconds late changes nothing.
public final class NetworkMonitor {

    /// Called on the main thread, only when the network actually changed.
    public var onChange: ((String?) -> Void)?

    public private(set) var currentProfileID: String?

    private let interval: TimeInterval
    private let read: () -> String?
    private var timer: DispatchSourceTimer?

    /// `read` is injectable so the decision can be exercised without Wi-Fi.
    public init(interval: TimeInterval = 5, read: @escaping () -> String? = CurrentNetwork.profileID) {
        self.interval = interval
        self.read = read
    }

    public func start() {
        guard timer == nil else { return }
        currentProfileID = read()
        Log.info("Network monitor started, \(Self.describe(currentProfileID))")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Enough of the identity to tell one network from another in a log, and to
    /// check by hand that it does **not** change when walking between the nodes
    /// of one mesh - which is the whole reason the network is identified by its
    /// profile rather than by the access point it happens to be talking to.
    static func describe(_ profileID: String?) -> String {
        guard let profileID, !profileID.isEmpty else { return "on no Wi-Fi network" }
        return "on Wi-Fi network \(profileID.prefix(8))…"
    }

    private func poll() {
        let latest = read()
        guard latest != currentProfileID else { return }
        currentProfileID = latest
        Log.info("Wi-Fi network changed, now \(Self.describe(latest))")
        onChange?(latest)
    }
}
