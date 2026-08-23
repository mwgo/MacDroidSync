import AppKit
import Foundation

/// Locks this Mac's screen.
///
/// macOS has no public call for "lock the screen now". The one the system itself
/// uses lives in a private framework, and it is the only option that locks
/// instantly, needs no Accessibility permission and does not depend on the
/// user's "require password after sleep" delay. It is looked up at runtime, so a
/// future macOS that drops the symbol falls back to sleeping the display instead
/// of crashing.
public enum ScreenLocker {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    private static let symbolName = "SACLockScreenImmediate"

    private typealias LockFunction = @convention(c) () -> Int32

    /// Resolved once: dlopen keeps the handle for the lifetime of the process.
    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown reason"
            Log.error("Could not open login.framework: \(reason)")
            return nil
        }
        guard let symbol = dlsym(handle, symbolName) else {
            Log.error("\(symbolName) is not available on this macOS")
            return nil
        }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    /// True once the screen is actually locked.
    @discardableResult
    public static func lock() -> Bool {
        if let lockFunction {
            let result = lockFunction()
            if result == 0 {
                Log.info("Screen locked")
                return true
            }
            Log.error("\(symbolName) returned \(result), sleeping the display instead")
        }
        return sleepDisplay()
    }

    /// Fallback: this only locks when the user asks for the password right after
    /// the display sleeps, hence the hint in the log.
    private static func sleepDisplay() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            Log.info("Display put to sleep; it only locks if a password is required immediately")
            return process.terminationStatus == 0
        } catch {
            Log.error("Could not sleep the display: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether the login window is already covering the session. Locking twice
    /// is harmless but pointless, and this also keeps the menu honest.
    public static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The system tells every application when the screen is locked and
    /// unlocked; both are needed to stop measuring while nobody is there.
    public static func observeLockState(
        onLocked: @escaping () -> Void,
        onUnlocked: @escaping () -> Void
    ) -> [NSObjectProtocol] {
        let center = DistributedNotificationCenter.default()
        return [
            center.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in onLocked() },
            center.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in onUnlocked() },
        ]
    }
}
