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
        static let autoLockEnabled = "autoLockEnabled"
        static let autoLockPreset = "autoLockPreset"
        static let autoLockAwayThreshold = "autoLockAwayThreshold"
        static let autoLockSnoozeUntil = "autoLockSnoozeUntil"
        static let photosEnabled = "photosEnabled"
        static let photosAlbumIdentifier = "photosAlbumIdentifier"
    }

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore(service: Log.subsystem, account: "pairing-code")
    private let fallbackURL = AppPaths.supportDirectory.appendingPathComponent("pairing-code")
    /// Guards the lazy generation of the pairing code against two threads
    /// racing to create two different codes.
    private let pairingLock = NSLock()
    /// The keychain read behind `pairingCode` can take seconds the first time,
    /// and the menu bar asks for the code often, so the answer is kept. Its own
    /// lock, held for nanoseconds, means `knownPairingCode` can never end up
    /// waiting behind a slow keychain read.
    private var cachedPairingCode: String?
    private let cacheLock = NSLock()

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
            if let known = knownPairingCode { return known }

            switch Self.resolve(keychain.read(), fallback: readFallback()) {
            case .use(let code):
                remember(pairingCode: code)
                return code
            case .generate:
                let generated = CryptoBox.generatePairingCode()
                persist(pairingCode: generated)
                Log.info("No pairing code stored yet, generated one")
                return generated
            case .unavailable(let status):
                Log.error(
                    "Could not read the pairing code (OSStatus \(status)). "
                    + "Keeping the stored one instead of minting a new pairing."
                )
                return ""
            }
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

    /// The code if it is already in hand, without ever touching the keychain.
    /// Callers on the main thread use this instead of `pairingCode`.
    public var knownPairingCode: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedPairingCode
    }

    private func remember(pairingCode code: String) {
        cacheLock.lock()
        cachedPairingCode = code
        cacheLock.unlock()
    }

    private func persist(pairingCode code: String) {
        remember(pairingCode: code)
        if keychain.write(code) {
            try? FileManager.default.removeItem(at: fallbackURL)
        } else {
            writeFallback(code)
        }
    }

    /// What to do about the pairing code, given what the keychain said.
    ///
    /// The distinction that matters is between "there is no item" and "the read
    /// failed". Treating a failure as "no code yet" mints a fresh code **over a
    /// perfectly good one** and silently breaks the pairing with the phone: the
    /// clipboard, the files and the presence beacon all stop working until the
    /// user pairs again. That is exactly what happened once, when a read landed
    /// in the moment the system was going to sleep.
    enum Resolution: Equatable {
        case use(String)
        case generate
        case unavailable(OSStatus)
    }

    static func resolve(_ outcome: KeychainOutcome, fallback: String?) -> Resolution {
        if case .found(let code) = outcome, !code.isEmpty { return .use(code) }
        if let fallback, !fallback.isEmpty { return .use(fallback) }
        switch outcome {
        case .absent:
            return .generate
        case .failed(let status):
            // No fallback and no answer: refuse rather than overwrite.
            return .unavailable(status)
        case .found:
            // An empty item is as good as none.
            return .generate
        }
    }

    // MARK: - Photos

    /// Whether photos from the phone are taken into the Photos library.
    ///
    /// Off until asked for, like the auto lock and for the same kind of reason:
    /// turning it on is what triggers the system's Photos prompt, and it is the
    /// switch this feature is required to have.
    public var photosEnabled: Bool {
        get { defaults.bool(forKey: Keys.photosEnabled) }
        set { defaults.set(newValue, forKey: Keys.photosEnabled) }
    }

    /// The album imports go into, by identifier rather than by title: titles are
    /// not unique and the user may rename the album without breaking anything.
    public var photosAlbumIdentifier: String? {
        get { defaults.string(forKey: Keys.photosAlbumIdentifier) }
        set { defaults.set(newValue, forKey: Keys.photosAlbumIdentifier) }
    }

    // MARK: - Auto lock

    /// Off until the user asks for it: starting the scanner is what triggers the
    /// system's Bluetooth prompt, and the RSSI threshold wants calibrating.
    public var autoLockEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoLockEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoLockEnabled) }
    }

    /// Name of the chosen preset; anything unknown falls back to balanced.
    public var autoLockPreset: String {
        get { defaults.string(forKey: Keys.autoLockPreset) ?? "Balanced" }
        set { defaults.set(newValue, forKey: Keys.autoLockPreset) }
    }

    /// Manual override of the away threshold in dBm, 0 meaning "use the preset".
    /// Radios differ by more than ten dB, so this is the one number worth
    /// tuning after watching the live reading in the menu.
    public var autoLockAwayThreshold: Double {
        get { defaults.double(forKey: Keys.autoLockAwayThreshold) }
        set { defaults.set(newValue, forKey: Keys.autoLockAwayThreshold) }
    }

    /// The preset with the override applied, ready for `PresenceScanner`.
    public var presenceSettings: PresenceSettings {
        var settings: PresenceSettings
        switch autoLockPreset {
        case "Fast": settings = .fast
        case "Cautious": settings = .cautious
        default: settings = .balanced
        }
        let override = autoLockAwayThreshold
        if override < 0 {
            // The hysteresis gap of the preset is kept, so a custom threshold
            // still cannot make the state flap.
            let gap = settings.nearThreshold - settings.awayThreshold
            settings.awayThreshold = override
            settings.nearThreshold = override + gap
        }
        return settings
    }

    /// While this is in the future the auto lock stays out of the way.
    public var autoLockSnoozeUntil: Date? {
        get {
            let stored = defaults.double(forKey: Keys.autoLockSnoozeUntil)
            guard stored > 0 else { return nil }
            let date = Date(timeIntervalSince1970: stored)
            return date > Date() ? date : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.autoLockSnoozeUntil) }
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

/// What one keychain read found. `absent` and `failed` look the same to a
/// caller that only gets an optional back, and telling them apart is what keeps
/// a transient failure from overwriting the pairing code.
enum KeychainOutcome: Equatable {
    case found(String)
    case absent
    case failed(OSStatus)
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

    func read() -> KeychainOutcome {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                return .failed(status)
            }
            return .found(text)
        case errSecItemNotFound:
            return .absent
        default:
            return .failed(status)
        }
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
