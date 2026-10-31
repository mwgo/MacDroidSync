import Foundation

/// A file or folder as both sides last had it, after a cycle left them the same.
public struct FolderBase: Codable, Equatable {
    public var path: String
    /// nil for a folder.
    public var sha: String?

    public init(path: String, sha: String?) {
        self.path = path
        self.sha = sha
    }

    public var isDirectory: Bool { sha == nil }
}

/// What one cycle does to one pair of folders, worked out from what both sides
/// had after the last cycle and what each has now. Paths are compared by
/// `FolderRules.key`; the steps name them by key too.
public enum FolderSyncPlan {

    public enum Step: Hashable {
        case makeDirOnMac(String)
        case makeDirOnPhone(String)
        /// The same file, or folder, on both sides: remembered as the base.
        case same(String)
        case toMac(String)
        case toPhone(String)
        /// Changed on both sides: the Mac's version keeps the path, the phone's a name of its own.
        case conflict(String)
        case moveOnMac(from: String, to: String)
        case moveOnPhone(from: String, to: String)
        /// Deleted on the phone while changed on the Mac: it goes back to the phone.
        case restoreOnPhone(String)
        /// Deleted on the Mac while changed on the phone: it goes back to the Mac.
        case restoreOnMac(String)
        case deleteOnMac(String)
        case deleteOnPhone(String)
        /// Removed only when empty once the files in it are gone.
        case removeDirOnMac(String)
        case removeDirOnPhone(String)
        /// Gone on both sides.
        case forget(String)
    }

    public enum Blocked: Equatable {
        /// The phone shows nothing where the last cycle left files: a lost
        /// permission or a missing card rather than everything deleted.
        case phoneEmpty
        case macEmpty
    }

    public struct Result: Equatable {
        public var steps: [Step] = []
        /// Deletions left undone because there were too many at once.
        public var heldDeletions = 0
        public var blocked: Blocked?
    }

    /// More deletions than this at once wait for the user, whichever side they
    /// come from.
    public static func deletionLimit(files: Int) -> Int { max(5, files / 5) }

    /// `pending` are the Mac's paths, by key, left alone for now: not on this
    /// Mac yet, being written, or gone only a moment ago from iCloud Drive.
    /// `settling` are those of them gone from iCloud Drive: one whose contents
    /// turn up under another name was moved, and is moved on the phone at once.
    public static func plan(
        base: [String: FolderBase],
        phone: [FolderEntry],
        mac: [FolderEntry],
        pending: Set<String> = [],
        settling: Set<String> = [],
        allowDeletions: Bool = false
    ) -> Result {
        let phoneByKey = index(phone)
        let macByKey = index(mac)
        var result = Result()

        let baseFiles = base.values.filter { !$0.isDirectory }.count
        if baseFiles > 0 && !allowDeletions {
            if !phone.contains(where: { !$0.isDirectory }) {
                result.blocked = .phoneEmpty
                return result
            }
            if !mac.contains(where: { !$0.isDirectory }) && pending.isEmpty {
                result.blocked = .macEmpty
                return result
            }
        }

        var dirs: [Step] = []
        var files: [Step] = []
        var deleteOnMac: [String: String] = [:]
        var deleteOnPhone: [String: String] = [:]
        var newOnPhone: [String: String] = [:]
        var newOnMac: [String: String] = [:]
        var removeDirs: [Step] = []

        let keys = Set(base.keys).union(phoneByKey.keys).union(macByKey.keys)
        for key in keys.sorted() where !pending.contains(key) {
            let was = base[key]
            let p = phoneByKey[key]
            let m = macByKey[key]

            if (p?.isDirectory ?? was?.isDirectory ?? false) || (m?.isDirectory ?? false) {
                // A folder, or a folder on one side and a file on the other: the
                // file wins, the folder stays where it is.
                if let p, let m, p.isDirectory != m.isDirectory { continue }
                switch (p, m) {
                case (nil, nil): files.append(.forget(key))
                case (.some, .some): if was == nil { files.append(.same(key)) }
                case (.some, nil): dirs.append(was == nil ? .makeDirOnMac(key) : .removeDirOnPhone(key))
                case (nil, .some): dirs.append(was == nil ? .makeDirOnPhone(key) : .removeDirOnMac(key))
                }
                continue
            }

            switch (p?.h, m?.h) {
            case (nil, nil):
                if was != nil { files.append(.forget(key)) }
            case (let ph?, let mh?):
                let phoneChanged = ph != was?.sha
                let macChanged = mh != was?.sha
                if ph == mh {
                    if was?.sha != ph { files.append(.same(key)) }
                } else if was == nil || (phoneChanged && macChanged) {
                    files.append(.conflict(key))
                } else if phoneChanged {
                    files.append(.toMac(key))
                } else if macChanged {
                    files.append(.toPhone(key))
                }
            case (let ph?, nil):
                if let was {
                    if ph != was.sha { files.append(.restoreOnMac(key)) } else { deleteOnPhone[key] = ph }
                } else {
                    newOnPhone[key] = ph
                }
            case (nil, let mh?):
                if let was {
                    if mh != was.sha { files.append(.restoreOnPhone(key)) } else { deleteOnMac[key] = mh }
                } else {
                    newOnMac[key] = mh
                }
            }
        }

        // A file gone from one place and new in another with the same contents
        // was moved, and is moved on the other side too rather than sent again.
        var moves: [Step] = []
        for (to, sha) in newOnPhone.sorted(by: { $0.key < $1.key }) {
            if let from = uniqueKey(in: deleteOnMac, sha: sha), base[from]?.sha == sha {
                moves.append(.moveOnMac(from: from, to: to))
                deleteOnMac.removeValue(forKey: from)
            } else {
                files.append(.toMac(to))
            }
        }
        // Gone from iCloud Drive a moment ago, as it is on the phone still.
        var moved: [String: String] = [:]
        for key in settling where macByKey[key] == nil {
            if let sha = base[key]?.sha, phoneByKey[key]?.h == sha { moved[key] = sha }
        }
        var settled: Set<String> = []
        for (to, sha) in newOnMac.sorted(by: { $0.key < $1.key }) {
            if let from = uniqueKey(in: deleteOnPhone.merging(moved) { a, _ in a }, sha: sha), base[from]?.sha == sha {
                moves.append(.moveOnPhone(from: from, to: to))
                deleteOnPhone.removeValue(forKey: from)
                if moved.removeValue(forKey: from) != nil { settled.insert(from) }
            } else {
                files.append(.toPhone(to))
            }
        }
        // A folder is removed once nothing left for later is in it.
        let waiting = pending.subtracting(settled)
        dirs.removeAll { step in
            switch step {
            case .removeDirOnMac(let key), .removeDirOnPhone(let key):
                return waiting.contains { $0.hasPrefix(key + "/") }
            default:
                return false
            }
        }

        let deletions: [Step] = deleteOnMac.keys.sorted().map { .deleteOnMac($0) }
            + deleteOnPhone.keys.sorted().map { .deleteOnPhone($0) }
        let held = !allowDeletions && deletions.count > deletionLimit(files: baseFiles)
        for step in dirs {
            switch step {
            case .removeDirOnMac, .removeDirOnPhone: removeDirs.append(step)
            default: break
            }
        }
        // Parents before children when made, children before parents when removed.
        let made = dirs.filter { !removeDirs.contains($0) }.sorted { depth($0) < depth($1) }
        let removed = removeDirs.sorted { depth($0) > depth($1) }
        result.steps = made + moves + files + (held ? [] : deletions + removed)
        result.heldDeletions = held ? deletions.count : 0
        return result
    }

    public static func index(_ entries: [FolderEntry]) -> [String: FolderEntry] {
        Dictionary(entries.map { (FolderRules.key($0.p), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func uniqueKey(in candidates: [String: String], sha: String) -> String? {
        let matches = candidates.filter { $0.value == sha }
        return matches.count == 1 ? matches.first?.key : nil
    }

    private static func depth(_ step: Step) -> Int {
        switch step {
        case .makeDirOnMac(let key), .makeDirOnPhone(let key), .removeDirOnMac(let key), .removeDirOnPhone(let key):
            return key.split(separator: "/").count
        default:
            return 0
        }
    }
}
