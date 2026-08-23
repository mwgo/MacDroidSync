import Foundation
import os

/// Thin wrapper over os.Logger. Set MDS_VERBOSE=1 to also mirror the messages
/// on stdout, which is handy when the app is started from a terminal.
public enum Log {
    public static let subsystem = "pl.wojas.MacDroidSync"

    private static let mirrorToStdout = ProcessInfo.processInfo.environment["MDS_VERBOSE"] == "1"
    private static let sync = Logger(subsystem: subsystem, category: "sync")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func info(_ message: String) {
        sync.info("\(message, privacy: .public)")
        mirror("INFO ", message)
    }

    public static func error(_ message: String) {
        sync.error("\(message, privacy: .public)")
        mirror("ERROR", message)
    }

    public static func debug(_ message: String) {
        sync.debug("\(message, privacy: .public)")
        mirror("DEBUG", message)
    }

    private static func mirror(_ level: String, _ message: String) {
        guard mirrorToStdout else { return }
        print("\(formatter.string(from: Date())) \(level) \(message)")
        fflush(stdout)
    }
}
