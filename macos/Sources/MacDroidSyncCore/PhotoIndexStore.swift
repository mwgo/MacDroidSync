import Foundation

/// What this Mac has already taken from the phone, and what became of it.
///
/// The same shape as `OutboxStore` and `SafeNetworkStore`: one JSON file in the
/// support directory, one serial queue, an injectable URL so the tests never go
/// near the real one.
///
/// Two rules make this file the thing the whole feature leans on, and both are
/// about *not* doing something:
///
/// * A row is **never removed because the asset vanished from Photos**. That is
///   what `removedByUser` records, and it is why a photo the user deleted here
///   does not quietly come back on the next cycle.
/// * An unreadable file loads as **empty**, which biases the feature towards
///   asking the phone again rather than towards deleting. Empty means "I know of
///   nothing", and knowing of nothing can only ever cause a re-import - never a
///   deletion, because deletions are computed from rows that exist.
public final class PhotoIndexStore {

    private let url: URL
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-index")
    private var entries: [String: PhotoIndexEntry]

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("photos-index.json")
        self.entries = Self.load(from: self.url)
    }

    // MARK: - Reading

    public var all: [PhotoIndexEntry] {
        queue.sync { Array(entries.values) }
    }

    public func entry(for key: String) -> PhotoIndexEntry? {
        queue.sync { entries[key] }
    }

    public func count(in state: PhotoIndexState) -> Int {
        queue.sync { entries.values.filter { $0.state == state }.count }
    }

    /// Nothing has ever been delivered, so the next plan is a first run and only
    /// reports. Rows the user deleted count as delivery: the report is a safety
    /// net for a fresh install, not something to see again after a clear-out.
    public var isFirstRun: Bool {
        queue.sync { entries.values.allSatisfy { $0.state == .deletedByUs } }
    }

    /// The assets to remove from Photos, oldest request first.
    public var pendingDeletions: [PhotoIndexEntry] {
        queue.sync {
            entries.values
                .filter { $0.state == .pendingDelete && $0.localIdentifier != nil }
                .sorted { $0.importedAt < $1.importedAt }
        }
    }

    // MARK: - Writing

    public func upsert(_ entry: PhotoIndexEntry) {
        queue.sync {
            entries[entry.key] = entry
            persist()
        }
    }

    public func mark(_ keys: [String], as state: PhotoIndexState) {
        guard !keys.isEmpty else { return }
        queue.sync {
            for key in keys {
                guard var entry = entries[key] else { continue }
                entry.state = state
                entries[key] = entry
            }
            persist()
        }
    }

    /// A key that moved: the same asset under a new name. The bytes and the
    /// asset stay exactly where they are.
    public func rename(from: String, to: String) {
        queue.sync {
            guard var entry = entries.removeValue(forKey: from) else { return }
            entry.key = to
            entries[to] = entry
            persist()
        }
    }

    /// After the operator confirmed a removal: the row stays, as a record that
    /// this key was here and is gone.
    public func markDeleted(_ keys: [String]) {
        mark(keys, as: .deletedByUs)
    }

    /// Used only when the whole feature is reset by the user.
    public func removeAll() {
        queue.sync {
            entries.removeAll()
            persist()
        }
    }

    // MARK: - Storage

    private func persist() {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        AppPaths.ensureSupportDirectory()
        do {
            let sorted = entries.values.sorted { $0.key < $1.key }
            try JSONEncoder().encode(sorted).write(to: url, options: .atomic)
        } catch {
            Log.error("Could not save the photo index: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [String: PhotoIndexEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let rows = try? JSONDecoder().decode([PhotoIndexEntry].self, from: data) else {
            Log.error("The photo index is unreadable; starting from an empty one")
            return [:]
        }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
