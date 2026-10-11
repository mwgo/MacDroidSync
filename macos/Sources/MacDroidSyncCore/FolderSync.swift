import CryptoKit
import Foundation

/// Lowercase hex SHA-256, the form the phone uses for its checksums.
public func folderSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A folder on the phone kept the same as one on this Mac.
public struct FolderPair: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// On the phone, relative to its shared storage, e.g. `Documents/Notes MD`.
    public var phonePath: String
    /// On this Mac, a local folder or one on iCloud Drive.
    public var macPath: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, phonePath: String, macPath: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.phonePath = phonePath
        self.macPath = macPath
        self.enabled = enabled
    }

    public var macURL: URL { URL(fileURLWithPath: macPath, isDirectory: true) }
}

/// One file or folder of a synced folder, its path relative to the folder's
/// root with `/` between the parts. See PROTOCOL.md section 10.
public struct FolderEntry: Codable, Equatable {
    /// The path.
    public var p: String
    /// Size in bytes; 0 for a folder.
    public var s: Int64
    /// Modified, milliseconds.
    public var m: Int64
    /// Lowercase hex SHA-256 of a file; nil for a folder.
    public var h: String?
    /// Set for a folder.
    public var d: Bool?

    public init(p: String, s: Int64 = 0, m: Int64 = 0, h: String? = nil, d: Bool? = nil) {
        self.p = p
        self.s = s
        self.m = m
        self.h = h
        self.d = d
    }

    public var isDirectory: Bool { d == true }
}

/// A pair as the phone is told of it in `folders-config`, and as it answers.
public struct FolderPairConfig: Codable, Equatable {
    public var id: String
    public var path: String?
    public var ok: Bool?
    public var reason: String?

    public init(id: String, path: String? = nil, ok: Bool? = nil, reason: String? = nil) {
        self.id = id
        self.path = path
        self.ok = ok
        self.reason = reason
    }
}

/// The `folder` field of a message. Which fields are set depends on the type,
/// see the table in PROTOCOL.md section 10.
public struct FolderPayload: Codable, Equatable {
    public var requestId: String?
    public var pairs: [FolderPairConfig]?
    public var pair: String?
    public var cursor: Int?
    public var entries: [FolderEntry]?
    public var path: String?
    /// The new path of a `folder-move`.
    public var to: String?
    public var offset: Int64?
    public var total: Int64?
    public var sha256: String?
    /// What the file on the phone must still be for a write, move or deletion
    /// to go ahead; absent for a file that must not exist yet.
    public var baseHash: String?
    public var dir: Bool?
    /// In `folder-changed`: what changed, when the phone knows.
    public var paths: [String]?

    public init(
        requestId: String? = nil,
        pairs: [FolderPairConfig]? = nil,
        pair: String? = nil,
        cursor: Int? = nil,
        entries: [FolderEntry]? = nil,
        path: String? = nil,
        to: String? = nil,
        offset: Int64? = nil,
        total: Int64? = nil,
        sha256: String? = nil,
        baseHash: String? = nil,
        dir: Bool? = nil,
        paths: [String]? = nil
    ) {
        self.requestId = requestId
        self.pairs = pairs
        self.pair = pair
        self.cursor = cursor
        self.entries = entries
        self.path = path
        self.to = to
        self.offset = offset
        self.total = total
        self.sha256 = sha256
        self.baseHash = baseHash
        self.dir = dir
        self.paths = paths
    }
}

/// One message from the phone about the folders, with what the message itself says.
public struct FolderReply {
    public var type: String
    public var payload: FolderPayload
    public var ok: Bool
    public var reason: String?
    /// A piece of a file, for `folder-get`.
    public var data: Data?

    public init(type: String, payload: FolderPayload, ok: Bool, reason: String?, data: Data?) {
        self.type = type
        self.payload = payload
        self.ok = ok
        self.reason = reason
        self.data = data
    }
}

/// Names that never travel: the Finder's and the system's own files, and the
/// sync's pieces in progress.
public enum FolderRules {
    /// Larger files are left where they are and reported.
    public static let maxFileSize: Int64 = 512 * 1024 * 1024
    /// Raw bytes per `folder-get` or `folder-put` piece; as on the phone.
    public static let chunk = 1024 * 1024
    /// Where the phone keeps its trash and its pieces in progress, in each folder.
    public static let phoneDirectory = ".macdroidsync"

    public static func isExcluded(name: String) -> Bool {
        name == ".DS_Store"
            || name.hasPrefix("._")
            || name == "Icon\r"
            || name.hasPrefix(".Trash")
            || name == phoneDirectory
            || name.hasSuffix(".part")
            || name.hasSuffix(".macdroidsync-part")
            || name == ".localized"
    }

    /// Whether a path as the phone or the Mac gives it is a safe path within
    /// the folder: relative, no `..`, nothing excluded on the way.
    public static func isValid(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !isExcluded(name: String($0))
        }
    }

    /// The key two paths are the same file by: the same letters, composed the
    /// same way, whatever their case. Both the Mac's disks and the phone's
    /// shared storage ignore case.
    public static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `name (Android, Oct 11 14:05).ext`, the name a phone's version keeps when
    /// both sides changed a file.
    public static func conflictPath(_ path: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH.mm"
        let suffix = " (Android, \(formatter.string(from: date)))"
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let base = ext.isEmpty ? path : String(path.dropLast(ext.count + 1))
        return ext.isEmpty ? base + suffix : base + suffix + "." + ext
    }
}

/// What the apps that use a synced folder and MacDroidSync tell each other on
/// this Mac, through the distributed notification centre. The object of each is
/// a path: notes apps may run sandboxed, and a sandboxed app's `userInfo` is
/// dropped on the way.
public enum FolderEvents {
    /// Posted by an app that changed files in a synced folder; the object is
    /// the file or folder it changed. The sync looks at that folder at once.
    public static let folderChanged = Notification.Name("pl.mwgo.MacDroidSync.folderChanged")
    /// Posted by MacDroidSync after a sync wrote into a folder; the object is
    /// the folder's path.
    public static let filesChanged = Notification.Name("pl.mwgo.MacDroidSync.filesChanged")
}
