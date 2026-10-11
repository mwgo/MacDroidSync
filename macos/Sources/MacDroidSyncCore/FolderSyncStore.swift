import Foundation

/// Something the folder sync could not settle by itself.
public struct FolderConflict: Codable, Equatable, Identifiable {
    /// Plain words rather than an enum, so that an older build reading a newer
    /// file shows the entry instead of failing to read the whole list.
    public enum Kind {
        /// Changed on both sides: the Mac's version kept the path, the phone's `copy`.
        public static let edited = "edited"
        /// Deleted on the phone while changed on the Mac: it came back to the phone.
        public static let deletedOnPhone = "deletedOnPhone"
        /// Deleted on the Mac while changed on the phone: it came back to the Mac.
        public static let deletedOnMac = "deletedOnMac"
        /// More deletions at once than the sync carries out unasked.
        public static let deletions = "deletions"
        /// One side shows an empty folder where files were.
        public static let empty = "empty"
        /// Too large to send.
        public static let tooBig = "tooBig"
    }

    public var id: String
    public var at: Int64
    public var kind: String
    public var path: String
    /// The name the phone's version was kept under.
    public var copy: String?
    public var count: Int?

    public init(id: String = UUID().uuidString, at: Int64, kind: String, path: String, copy: String? = nil, count: Int? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.path = path
        self.copy = copy
        self.count = count
    }
}

/// What the sync knows of one pair of folders, on disk in
/// `~/Library/Application Support/MacDroidSync/FolderSync/<pair>.json`, folder
/// 0700 and file 0600.
public final class FolderSyncStore {

    public struct State: Codable, Equatable {
        public var base: [String: FolderBase] = [:]
        /// When a file the base holds was first missed on the Mac, seconds.
        public var missingSince: [String: Double] = [:]
        public var conflicts: [FolderConflict] = []
        /// The two folders the base belongs to; others start afresh.
        public var macPath: String?
        public var phonePath: String?
        /// Checksums of the Mac's files by key, as of a size and modification time.
        public var hashes: [String: CachedHash] = [:]
        public var lastSync: Double?

        public init() {}
    }

    public struct CachedHash: Codable, Equatable {
        public var size: Int64
        public var modified: Int64
        public var sha: String
    }

    public let pairId: String
    public let directory: URL
    public private(set) var state: State

    private var url: URL { directory.appendingPathComponent("\(pairId).json") }
    /// Scratch space for the files coming from the phone, on the same disk as
    /// this Mac's home so they move into place in one step.
    public var workDirectory: URL { directory.appendingPathComponent("work-\(pairId)", isDirectory: true) }

    public init(pairId: String, directory: URL = AppPaths.supportDirectory.appendingPathComponent("FolderSync", isDirectory: true)) {
        self.pairId = pairId
        self.directory = directory
        let stored = (try? Data(contentsOf: directory.appendingPathComponent("\(pairId).json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = stored ?? State()
    }

    /// A base made against other folders means nothing for these.
    public func use(macPath: String, phonePath: String) {
        guard state.macPath != macPath || state.phonePath != phonePath else { return }
        if state.macPath != nil || state.phonePath != nil {
            state.base = [:]
            state.missingSince = [:]
            state.hashes = [:]
        }
        state.macPath = macPath
        state.phonePath = phonePath
        save()
    }

    public func setBase(_ key: String, _ entry: FolderBase?) {
        state.base[key] = entry
    }

    public func setMissing(_ missing: [String: Double]) {
        state.missingSince = missing
    }

    public func setHashes(_ hashes: [String: CachedHash]) {
        state.hashes = hashes
    }

    public func finishCycle(at date: Date) {
        state.lastSync = date.timeIntervalSince1970
        save()
    }

    public func addConflict(_ conflict: FolderConflict) {
        state.conflicts.removeAll { $0.kind == conflict.kind && $0.path == conflict.path && conflict.kind != FolderConflict.Kind.edited }
        state.conflicts.insert(conflict, at: 0)
        if state.conflicts.count > 200 { state.conflicts.removeLast(state.conflicts.count - 200) }
        save()
    }

    public func dismissConflict(id: String) {
        state.conflicts.removeAll { $0.id == id }
        save()
    }

    public func dismissConflicts(kind: String) {
        state.conflicts.removeAll { $0.kind == kind }
        save()
    }

    public func removeAll() {
        state = State()
        try? FileManager.default.removeItem(at: url)
        clearWork()
    }

    public func freshWorkFile() -> URL {
        ensure(workDirectory)
        return workDirectory.appendingPathComponent(UUID().uuidString)
    }

    public func clearWork() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    public func save() {
        ensure(directory)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("Could not save the folder sync state: \(error.localizedDescription)")
        }
    }

    private func ensure(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
