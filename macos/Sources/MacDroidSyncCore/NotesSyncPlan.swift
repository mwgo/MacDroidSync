import CryptoKit
import Foundation

/// Lowercase hex SHA-256, the form the phone uses for its checksums.
public func notesSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A note on this Mac, in the folder of notes.
public struct MacNoteInfo: Codable, Equatable {
    public var id: String
    public var name: String
    public var folder: String
    /// Milliseconds.
    public var modified: Int64
    /// The note's text in the phone's form and its pictures and files, hashed
    /// together as the phone does; what tells a change.
    public var hash: String

    public init(id: String, name: String, folder: String, modified: Int64, hash: String = "") {
        self.id = id
        self.name = name
        self.folder = folder
        self.modified = modified
        self.hash = hash
    }
}

/// One note on the phone and the one on the Mac it is kept the same as, with
/// what each looked like when they were last the same.
public struct NotesPair: Codable, Equatable {
    public var androidId: String
    public var macId: String
    public var androidHash: String
    public var androidFolder: String
    public var macHash: String
    public var macFolder: String
    /// The pictures and files the phone held for the note, path to checksum,
    /// so that only what changed is sent again.
    public var phoneAssets: [String: String]

    public init(
        androidId: String,
        macId: String,
        androidHash: String,
        androidFolder: String,
        macHash: String,
        macFolder: String,
        phoneAssets: [String: String] = [:]
    ) {
        self.androidId = androidId
        self.macId = macId
        self.androidHash = androidHash
        self.androidFolder = androidFolder
        self.macHash = macHash
        self.macFolder = macFolder
        self.phoneAssets = phoneAssets
    }
}

/// Something the sync could not settle by itself, shown in the conflicts window.
public struct NotesConflict: Codable, Equatable, Identifiable {
    /// Plain words rather than an enum, so that an older build reading a newer
    /// file shows the entry instead of failing to read the whole list.
    public enum Kind {
        /// Changed on both sides: the Mac's version stayed, the phone's became a copy.
        public static let edited = "edited"
        /// Deleted on the phone while changed here: it came back to the phone.
        public static let deletedOnPhone = "deletedOnPhone"
        /// Deleted here while changed on the phone: it came back to Notes.
        public static let deletedOnMac = "deletedOnMac"
        /// More deletions at once than the sync carries out unasked.
        public static let deletions = "deletions"
    }

    public var id: String
    public var at: Int64
    public var kind: String
    public var title: String
    /// The two versions, pictures pointing at `asset:<sha256>` in the store.
    public var phoneMarkdown: String?
    public var macMarkdown: String?
    /// The title the phone's version was kept under.
    public var copyTitle: String?
    public var count: Int?

    public init(
        id: String = UUID().uuidString,
        at: Int64,
        kind: String,
        title: String,
        phoneMarkdown: String? = nil,
        macMarkdown: String? = nil,
        copyTitle: String? = nil,
        count: Int? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = title
        self.phoneMarkdown = phoneMarkdown
        self.macMarkdown = macMarkdown
        self.copyTitle = copyTitle
        self.count = count
    }
}

/// What one sync cycle does, worked out from the pairs and the two lists alone.
public enum NotesSyncPlan {

    public enum Step: Equatable {
        /// The phone's note changed: it replaces the one on the Mac.
        case pushToMac(androidId: String)
        /// The note on the Mac changed.
        case pullFromMac(macId: String)
        /// Both changed, if only one in its folder: a conflict when both texts did.
        case both(androidId: String)
        case createOnMac(androidId: String)
        case createOnPhone(macId: String)
        case deleteOnMac(macId: String)
        case deleteOnPhone(androidId: String)
        /// Deleted on the phone but changed on the Mac: it goes back to the phone.
        case restoreOnPhone(macId: String)
        /// Deleted on the Mac but changed on the phone: it goes back to the Mac.
        case restoreOnMac(androidId: String)
        /// Gone on both sides.
        case forget(androidId: String)
    }

    public struct Result: Equatable {
        public var steps: [Step]
        /// Deletions left undone because there were too many at once.
        public var heldDeletions: Int
    }

    /// What becomes of the folders. `known` are those both sides had after the
    /// last cycle: one of them missing on a side now was deleted there and
    /// goes on the other side too, once it is empty; a folder only the phone
    /// has and that is new is made in Notes. Without `known`, before the first
    /// cycle, nothing is deleted.
    public struct Folders: Equatable {
        public var createOnMac: [String] = []
        public var deleteOnPhone: [String] = []
        public var deleteOnMac: [String] = []
    }

    public static func folders(known: Set<String>?, phone: [String], mac: [String]) -> Folders {
        let onMac = Set(mac)
        let onPhone = Set(phone)
        var result = Folders()
        for folder in phone where !onMac.contains(folder) {
            if known?.contains(folder) == true {
                result.deleteOnPhone.append(folder)
            } else {
                result.createOnMac.append(folder)
            }
        }
        for folder in mac where !onPhone.contains(folder) && known?.contains(folder) == true {
            result.deleteOnMac.append(folder)
        }
        return result
    }

    /// More deletions than this at once wait for the operator, whichever side
    /// they come from: a phone that lost its notes folder must not empty Notes.
    public static func deletionLimit(pairs: Int) -> Int { max(5, pairs / 5) }

    public static func plan(
        pairs: [NotesPair],
        phone: [NoteEntry],
        mac: [MacNoteInfo],
        allowDeletions: Bool = false
    ) -> Result {
        let phoneById = Dictionary(phone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let macById = Dictionary(mac.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var steps: [Step] = []
        var deletions: [Step] = []

        for pair in pairs {
            let entry = phoneById[pair.androidId].flatMap { $0.isDeleted ? nil : $0 }
            let note = macById[pair.macId]
            let phoneChanged = entry.map { $0.hash != pair.androidHash || $0.folder != pair.androidFolder } ?? false
            let macChanged = note.map { $0.hash != pair.macHash || $0.folder != pair.macFolder } ?? false
            switch (entry, note) {
            case (nil, nil):
                steps.append(.forget(androidId: pair.androidId))
            case (nil, .some):
                if macChanged {
                    steps.append(.restoreOnPhone(macId: pair.macId))
                } else {
                    deletions.append(.deleteOnMac(macId: pair.macId))
                }
            case (.some, nil):
                if phoneChanged {
                    steps.append(.restoreOnMac(androidId: pair.androidId))
                } else {
                    deletions.append(.deleteOnPhone(androidId: pair.androidId))
                }
            case (.some, .some):
                switch (phoneChanged, macChanged) {
                case (true, true): steps.append(.both(androidId: pair.androidId))
                case (true, false): steps.append(.pushToMac(androidId: pair.androidId))
                case (false, true): steps.append(.pullFromMac(macId: pair.macId))
                case (false, false): break
                }
            }
        }

        let pairedPhone = Set(pairs.map(\.androidId))
        let pairedMac = Set(pairs.map(\.macId))
        for entry in phone where !entry.isDeleted && !pairedPhone.contains(entry.id) {
            steps.append(.createOnMac(androidId: entry.id))
        }
        for note in mac where !pairedMac.contains(note.id) {
            steps.append(.createOnPhone(macId: note.id))
        }

        let held = !allowDeletions && deletions.count > deletionLimit(pairs: pairs.count)
        return Result(steps: held ? steps : steps + deletions, heldDeletions: held ? deletions.count : 0)
    }
}

/// The pairs and conflicts on disk, and the pictures and files the sync has
/// seen, kept by checksum. `~/Library/Application Support/MacDroidSync/NotesFolder`,
/// folder 0700 and files 0600 like the messages. Its own directory, apart from
/// the one of the sync with Notes this replaced, so that it starts afresh.
public final class NotesSyncStore {

    public struct State: Codable, Equatable {
        public var pairs: [NotesPair] = []
        public var conflicts: [NotesConflict] = []
        public var version: Int?
        /// The folders both sides had after the last cycle, or a deletion on one
        /// side not yet carried out on the other; nil before the first cycle.
        public var folders: [String]?
        /// The folder of notes the pairs belong to; another one starts afresh.
        public var root: String?

        public init(version: Int? = 4) {
            self.version = version
        }
    }

    public let directory: URL
    public private(set) var state: State

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var assetDirectory: URL { directory.appendingPathComponent("assets", isDirectory: true) }
    /// Scratch space for the files of one note at a time.
    public var workDirectory: URL { directory.appendingPathComponent("work", isDirectory: true) }

    public init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("NotesFolder", isDirectory: true)) {
        self.directory = directory
        let stored = (try? Data(contentsOf: directory.appendingPathComponent("state.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = stored ?? State()
    }

    public var pairs: [NotesPair] { state.pairs }
    public var conflicts: [NotesConflict] { state.conflicts }

    public func pair(androidId: String) -> NotesPair? { state.pairs.first { $0.androidId == androidId } }
    public func pair(macId: String) -> NotesPair? { state.pairs.first { $0.macId == macId } }

    public func setPair(_ pair: NotesPair) {
        state.pairs.removeAll { $0.androidId == pair.androidId || $0.macId == pair.macId }
        state.pairs.append(pair)
        save()
    }

    public func removePair(androidId: String) {
        state.pairs.removeAll { $0.androidId == androidId }
        save()
    }

    /// The Mac's ids of the pairs, after notes found to be one were merged.
    public func remapMacIds(_ canonical: (String) -> String) {
        var changed = false
        for index in state.pairs.indices {
            let id = canonical(state.pairs[index].macId)
            if id != state.pairs[index].macId {
                state.pairs[index].macId = id
                changed = true
            }
        }
        if changed { save() }
    }

    /// Pairs made against another folder of notes mean nothing for this one.
    public func use(root: String) {
        guard state.root != root else { return }
        if state.root != nil {
            state.pairs = []
            state.folders = nil
        }
        state.root = root
        save()
    }

    public func setFolders(_ folders: Set<String>) {
        state.folders = folders.sorted()
        save()
    }

    public func addConflict(_ conflict: NotesConflict) {
        state.conflicts.removeAll { $0.kind == NotesConflict.Kind.deletions && conflict.kind == NotesConflict.Kind.deletions }
        state.conflicts.insert(conflict, at: 0)
        save()
    }

    public func dismissConflict(id: String) {
        state.conflicts.removeAll { $0.id == id }
        save()
    }

    public func removeAll() {
        state = State()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pictures and files

    public func assetURL(sha256: String) -> URL? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        return assetDirectory.appendingPathComponent(sha256)
    }

    public func hasAsset(sha256: String) -> Bool {
        assetURL(sha256: sha256).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    @discardableResult
    public func storeAsset(_ data: Data) -> String {
        let sha = notesSHA256(data)
        if let url = assetURL(sha256: sha), !FileManager.default.fileExists(atPath: url.path) {
            ensure(assetDirectory)
            try? data.write(to: url, options: .atomic)
        }
        return sha
    }

    public func asset(sha256: String) -> Data? {
        assetURL(sha256: sha256).flatMap { try? Data(contentsOf: $0) }
    }

    /// The copies of pictures and files no conflict shows any more.
    public func pruneAssets() {
        let shown = Set(state.conflicts.flatMap { [$0.phoneMarkdown, $0.macMarkdown].compactMap { $0 } }
            .flatMap { $0.components(separatedBy: "asset:").dropFirst().map { String($0.prefix(64)) } })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: assetDirectory.path)) ?? []
        for name in files where !shown.contains(name) {
            try? FileManager.default.removeItem(at: assetDirectory.appendingPathComponent(name))
        }
    }

    /// An empty folder of its own for the work on one note.
    public func freshWorkFolder() -> URL {
        let url = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ensure(url)
        return url
    }

    public func clearWork() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func save() {
        ensure(directory)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            Log.error("Could not save the notes sync state: \(error.localizedDescription)")
        }
    }

    private func ensure(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
