import CoreBluetooth
import Foundation

/// Listens for the phone's presence beacon and reports what to do about it.
///
/// Everything time based runs on the main queue, one tick a second, in the same
/// shape as `PowerMonitor`: the callbacks are safe to touch the menu bar from.
/// The measuring and the decision live in `PresenceEvaluator`; this type only
/// feeds it verified RSSI readings.
public final class PresenceScanner: NSObject {
    public enum Availability: String {
        /// Nothing has been started, so Bluetooth has not been touched at all.
        case stopped = "not scanning"
        case unknown = "starting up"
        case unsupported = "this Mac has no Bluetooth LE"
        case unauthorized = "Bluetooth permission was refused"
        case poweredOff = "Bluetooth is off"
        case scanning = "scanning"
    }

    /// The phone was recognised, with the reading that armed the feature.
    public var onArmed: ((Double) -> Void)?
    /// The mean dropped or the beacon stopped: the countdown has begun.
    public var onLeaving: (() -> Void)?
    /// It came back in time.
    public var onReturned: (() -> Void)?
    /// Time to lock the screen. Only ever fired after the phone was seen.
    public var onLock: (() -> Void)?
    public var onAvailabilityChange: ((Availability) -> Void)?

    public private(set) var availability: Availability = .stopped {
        didSet {
            guard availability != oldValue else { return }
            Log.info("Presence scanner: \(availability.rawValue)")
            onAvailabilityChange?(availability)
        }
    }

    public var settings: PresenceSettings {
        get { evaluator.settings }
        set { evaluator.settings = newValue }
    }

    public var state: PresenceState { evaluator.state }
    public var meanRSSI: Double? { evaluator.mean }
    public private(set) var lastRSSI: Double?
    public var isRunning: Bool { central != nil }

    /// Seconds since the last verified packet, nil when there was none.
    public var secondsSinceLastBeacon: TimeInterval? {
        evaluator.secondsSinceLastSample(at: now)
    }

    /// Time left before the screen is locked, nil unless the countdown is on.
    public var secondsUntilLock: TimeInterval? {
        evaluator.secondsUntilLock(at: now)
    }

    private let evaluator: PresenceEvaluator
    private var central: CBCentralManager?
    private var timer: DispatchSourceTimer?
    private var pairingCode = ""
    private var serviceUUID: CBUUID?
    private var lastRejectionLoggedAt: TimeInterval?

    public init(settings: PresenceSettings = .balanced) {
        self.evaluator = PresenceEvaluator(settings: settings)
        super.init()
    }

    /// Monotonic: unaffected by the clock being corrected mid measurement.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Lifecycle

    /// Starts listening for the beacon derived from this pairing code. Creating
    /// the central manager is what triggers the system's Bluetooth prompt, which
    /// is why it only happens once the user turns the feature on.
    public func start(pairingCode: String) {
        let uuid = CBUUID(nsuuid: PresenceBeacon.serviceUUID(pairingCode: pairingCode))
        if central != nil, uuid == serviceUUID { return }

        self.pairingCode = pairingCode
        self.serviceUUID = uuid
        evaluator.reset()
        lastRSSI = nil

        if central == nil {
            availability = .unknown
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            // A new pairing code means a different beacon to look for.
            restartScan()
        }
        startTicking()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        central?.stopScan()
        central = nil
        serviceUUID = nil
        evaluator.reset()
        lastRSSI = nil
        availability = .stopped
    }

    /// Forgets the history without giving up the scan, for example after the
    /// screen was locked by hand: the phone has to be seen again before
    /// anything can be locked automatically.
    public func rearm() {
        evaluator.reset()
        lastRSSI = nil
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func restartScan() {
        guard let central, let serviceUUID, central.state == .poweredOn else { return }
        central.stopScan()
        // Duplicates are the whole point: without them macOS reports the phone
        // once and there is nothing to average.
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        availability = .scanning
        Log.info("Listening for the presence beacon \(serviceUUID.uuidString)")
    }

    // MARK: - Decision

    private func tick() {
        switch evaluator.evaluate(at: now) {
        case .idle:
            break
        case .armed:
            Log.info("Phone recognised at \(formatted(evaluator.mean)), auto lock is armed")
            onArmed?(evaluator.mean ?? 0)
        case .leaving:
            // Two very different departures: the signal faded, or the packets
            // simply stopped. The second one is what walking away looks like.
            let detail = evaluator.mean.map { String(format: "mean %.0f dBm", $0) }
                ?? "the beacon stopped arriving"
            Log.info("Phone is leaving (\(detail)), locking in \(Int(settings.grace)) s unless it comes back")
            onLeaving?()
        case .returned:
            Log.info("Phone is back at \(formatted(evaluator.mean))")
            onReturned?()
        case .lock:
            guard !ScreenLocker.isScreenLocked else {
                Log.info("Phone is gone but the screen is already locked")
                return
            }
            Log.info("Phone stayed away for \(Int(settings.grace)) s, locking the screen")
            onLock?()
        }
    }

    private func formatted(_ mean: Double?) -> String {
        guard let mean else { return "no reading" }
        return String(format: "%.0f dBm", mean)
    }
}

// MARK: - CBCentralManagerDelegate

extension PresenceScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            restartScan()
        case .poweredOff:
            // Bluetooth off on this Mac must never read as "the phone left".
            evaluator.reset()
            lastRSSI = nil
            availability = .poweredOff
        case .unauthorized:
            availability = .unauthorized
        case .unsupported:
            availability = .unsupported
        default:
            availability = .unknown
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let payload = PresenceBeacon.payload(fromManufacturerData: raw)
        else { return }
        guard PresenceBeacon.verify(payload: payload, pairingCode: pairingCode) != nil else {
            logRejection()
            return
        }

        lastRSSI = RSSI.doubleValue
        evaluator.record(rssi: RSSI.intValue, at: now)
        Log.debug("Beacon at \(RSSI.intValue) dBm, mean \(formatted(evaluator.mean)) over \(evaluator.sampleCount) samples")
    }

    /// The beacon UUID matches but the token does not: different pairing codes,
    /// or clocks more than a minute apart. Worth saying out loud, but only once
    /// in a while - the packets keep coming.
    private func logRejection() {
        let moment = now
        if let last = lastRejectionLoggedAt, moment - last < 30 { return }
        lastRejectionLoggedAt = moment
        Log.info("Ignoring a beacon with a bad token: check the pairing code and the clock on both devices")
    }
}

private let tickInterval: DispatchTimeInterval = .seconds(1)
