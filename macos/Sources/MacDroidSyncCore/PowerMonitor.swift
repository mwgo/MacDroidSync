import AppKit
import Foundation
import IOKit

/// Watches the two situations in which this Mac stops being a usable peer:
/// it is going to sleep, or its lid is closed. A docked Mac keeps running with
/// the lid closed, so the lid is tracked separately from sleep.
public final class PowerMonitor {
    public enum Reason: String {
        case sleep = "the Mac is going to sleep"
        case lidClosed = "the lid is closed"
    }

    /// Called on the main thread. The handler must finish quickly: for sleep it
    /// runs inside the short window the system gives applications.
    public var onSuspend: ((Reason) -> Void)?
    public var onResume: (() -> Void)?

    public private(set) var isSuspended = false

    private let lidPollInterval: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var isAsleep = false
    private var isLidClosed = false

    public init(lidPollInterval: TimeInterval = 2) {
        self.lidPollInterval = lidPollInterval
    }

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.info("System is going to sleep")
            self.isAsleep = true
            self.evaluate()
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.info("System woke up")
            self.isAsleep = false
            self.isLidClosed = Self.isClamshellClosed() ?? self.isLidClosed
            self.evaluate()
        })

        isLidClosed = Self.isClamshellClosed() ?? false
        startLidPolling()
        Log.info("Power monitor started, lid \(isLidClosed ? "closed" : "open")")
        evaluate()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        timer?.cancel()
        timer = nil
    }

    /// There is no notification for the lid that works without private API, and
    /// reading one IORegistry property is cheap enough to poll.
    private func startLidPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + lidPollInterval, repeating: lidPollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let closed = Self.isClamshellClosed(), closed != self.isLidClosed else { return }
            Log.info("Lid \(closed ? "closed" : "opened")")
            self.isLidClosed = closed
            self.evaluate()
        }
        timer.resume()
        self.timer = timer
    }

    private func evaluate() {
        let shouldSuspend = isAsleep || isLidClosed
        guard shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        if shouldSuspend {
            onSuspend?(isAsleep ? .sleep : .lidClosed)
        } else {
            onResume?()
        }
    }

    /// Reads `AppleClamshellState` from IOPMrootDomain. Returns nil on a machine
    /// without a lid, such as a Mac mini.
    public static func isClamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        guard let number = value as? Bool else { return nil }
        return number
    }
}
