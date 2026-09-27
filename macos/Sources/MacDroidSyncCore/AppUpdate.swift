import CryptoKit
import Foundation

/// The Ed25519 public key release archives are signed with, base64 of the raw
/// 32 bytes. Nil until a key is generated with `Tools/sign-update.swift`; without
/// it an update is found and reported but never installed.
public enum UpdateKey {
    public static let publicKey: String? = nil
}

/// "0.2", "v0.10.1" - numeric parts compared one by one, missing parts as zero.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
        self.description = bare
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public struct AvailableUpdate: Equatable {
    public let version: AppVersion
    public let archiveURL: URL
    /// Nil for a release published without a signature, which is never installed.
    public let signatureURL: URL?
    public let pageURL: URL?

    public static func == (lhs: AvailableUpdate, rhs: AvailableUpdate) -> Bool {
        lhs.version == rhs.version && lhs.archiveURL == rhs.archiveURL && lhs.signatureURL == rhs.signatureURL
    }
}

public enum UpdateFeed {
    public static let repository = "mwgo/MacDroidSync"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    public static func archiveName(for version: AppVersion) -> String {
        "MacDroidSync-\(version)-macos.zip"
    }

    public static func signatureName(for version: AppVersion) -> String {
        archiveName(for: version) + ".sig"
    }

    public enum FeedError: Error, Equatable {
        case malformed
        case noArchive(String)
    }

    /// Reads GitHub's "latest release" answer. Nil when it is not newer than
    /// `current`, or is a draft or a prerelease.
    public static func update(from json: Data, newerThan current: AppVersion) throws -> AvailableUpdate? {
        guard let release = try? JSONDecoder().decode(Release.self, from: json),
              let version = AppVersion(release.tag_name)
        else { throw FeedError.malformed }
        guard release.draft != true, release.prerelease != true, version > current else { return nil }

        let assets = release.assets ?? []
        func url(named name: String) -> URL? {
            assets.first { $0.name == name }.flatMap { URL(string: $0.browser_download_url) }
        }
        guard let archive = url(named: archiveName(for: version)) else {
            throw FeedError.noArchive(archiveName(for: version))
        }
        return AvailableUpdate(
            version: version,
            archiveURL: archive,
            signatureURL: url(named: signatureName(for: version)),
            pageURL: release.html_url.flatMap(URL.init(string:))
        )
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let html_url: String?
        let assets: [Asset]?
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
}

public enum UpdateSignature {
    /// `signature` is the text of the `.sig` asset: base64 of 64 bytes.
    public static func isValid(archive: Data, signature: Data, publicKey: String) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let text = String(data: signature, encoding: .utf8),
              let signatureBytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(signatureBytes, for: archive)
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    /// A last check in the future means the clock was moved back; that counts as due.
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
    }
}
