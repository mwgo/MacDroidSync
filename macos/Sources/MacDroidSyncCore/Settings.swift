import AppKit
import Foundation
import ServiceManagement

/// Everything `SyncServer` needs to know about this Mac. Implemented by
/// `Settings` in the app and by a plain object in the tests.
public protocol SyncConfiguration: AnyObject {
    var port: UInt16 { get }
    var pairingCode: String { get }
    var deviceName: String { get }
    var deviceId: String { get }
    var pairedDeviceName: String? { get set }
}

/// User visible configuration. The pairing code lives in the login keychain and
/// falls back to a 0600 file next to the offline queue when the keychain is not
/// available (which happens for ad-hoc signed builds after a rebuild).
public final class Settings: SyncConfiguration {
    public static let shared = Settings()

    private enum Keys {
        static let port = "port"
        static let deviceId = "deviceId"
        static let pairedDeviceName = "pairedDeviceName"
    }

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore(service: Log.subsystem, account: "pairing-code")
    private let fallbackURL = AppPaths.supportDirectory.appendingPathComponent("pairing-code")
    /// Guards the lazy generation of the pairing code against two threads
    /// racing to create two different codes.
    private let pairingLock = NSLock()

    private init() {}

    public var port: UInt16 {
        get {
            let stored = defaults.integer(forKey: Keys.port)
            guard stored > 0, stored <= 65_535 else { return Wire.defaultPort }
            return UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: Keys.port) }
    }

    /// Stable identifier of this Mac, generated once.
    public var deviceId: String {
        if let existing = defaults.string(forKey: Keys.deviceId) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.deviceId)
        return generated
    }

    public var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Name of the phone we talked to last, shown in the menu while offline.
    public var pairedDeviceName: String? {
        get { defaults.string(forKey: Keys.pairedDeviceName) }
        set { defaults.set(newValue, forKey: Keys.pairedDeviceName) }
    }

    public var pairingCode: String {
        get {
            pairingLock.lock()
            defer { pairingLock.unlock() }
            if let code = keychain.read() ?? readFallback(), !code.isEmpty { return code }
            let generated = CryptoBox.generatePairingCode()
            persist(pairingCode: generated)
            return generated
        }
        set {
            pairingLock.lock()
            defer { pairingLock.unlock() }
            persist(pairingCode: newValue)
        }
    }

    public func regeneratePairingCode() -> String {
        pairingLock.lock()
        defer { pairingLock.unlock() }
        let code = CryptoBox.generatePairingCode()
        persist(pairingCode: code)
        return code
    }

    private func persist(pairingCode code: String) {
        if keychain.write(code) {
            try? FileManager.default.removeItem(at: fallbackURL)
        } else {
            writeFallback(code)
        }
    }

    // MARK: - Launch at login

    public var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Fallback storage

    private func readFallback() -> String? {
        guard let data = try? Data(contentsOf: fallbackURL) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeFallback(_ code: String) {
        AppPaths.ensureSupportDirectory()
        do {
            try Data(code.utf8).write(to: fallbackURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fallbackURL.path
            )
            Log.info("Pairing code stored in \(fallbackURL.path) (keychain unavailable)")
        } catch {
            Log.error("Could not persist the pairing code: \(error.localizedDescription)")
        }
    }
}

public enum AppPaths {
    /// The real home directory, even from inside an app sandbox.
    ///
    /// This matters for the Share extension: it runs sandboxed, and there both
    /// `NSHomeDirectory()` and the `FileManager` search paths point into its own
    /// container, so writing "Application Support" would land in
    /// `~/Library/Containers/…` where the app never looks. `getpwuid` is not
    /// redirected, and the entitlement grants access to that path.
    public static var homeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var supportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MacDroidSync", isDirectory: true)
    }

    @discardableResult
    public static func ensureSupportDirectory() -> URL {
        let url = supportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Minimal generic password wrapper.
struct KeychainStore {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            return update == errSecSuccess
        }
        return false
    }
}
