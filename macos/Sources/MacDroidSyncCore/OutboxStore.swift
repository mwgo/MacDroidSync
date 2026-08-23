import Foundation

/// Queue of files waiting to go to the phone.
///
/// Only paths are kept: a file on the Mac stays where it is, so copying it would
/// only waste disk. The trade off is that a file moved or deleted before its turn
/// can no longer be sent, which `first()` reports by skipping it.
public final class OutboxStore {
    public struct Item: Codable, Equatable {
        public let id: String
        public let path: String
        public let ts: Int64

        public var url: URL { URL(fileURLWithPath: path) }
        public var name: String { url.lastPathComponent }
    }

    private let url: URL
    private let queue = DispatchQueue(label: "\(Log.subsystem).outbox")
    private var items: [Item]

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("outbox.json")
        self.items = Self.load(from: self.url)
    }

    /// Everything queued, oldest first, including entries whose file is gone.
    public var all: [Item] {
        queue.sync { items }
    }

    public var count: Int {
        queue.sync { items.count }
    }

    @discardableResult
    public func enqueue(_ urls: [URL]) -> [Item] {
        queue.sync {
            let now = Message.now()
            let added = urls.map { Item(id: UUID().uuidString, path: $0.path, ts: now) }
            items.append(contentsOf: added)
            persist()
            for item in added { Log.info("Queued \(item.name) for the phone") }
            return added
        }
    }

    /// Oldest item whose file is still there. Vanished entries are dropped and
    /// reported, so the caller can tell the user instead of retrying forever.
    public func first(onMissing: ((Item) -> Void)? = nil) -> Item? {
        queue.sync {
            var dropped: [Item] = []
            defer {
                if !dropped.isEmpty {
                    persist()
                    dropped.forEach { onMissing?($0) }
                }
            }
            while let candidate = items.first {
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                Log.info("Dropping \(candidate.name) from the queue, the file is gone")
                items.removeFirst()
                dropped.append(candidate)
            }
            return nil
        }
    }

    public func remove(id: String) {
        queue.sync {
            items.removeAll { $0.id == id }
            persist()
        }
    }

    public func clear() {
        queue.sync {
            items.removeAll()
            persist()
        }
    }

    // MARK: - Persistence

    private func persist() {
        AppPaths.ensureSupportDirectory()
        do {
            if items.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try JSONEncoder().encode(items).write(to: url, options: .atomic)
            }
        } catch {
            Log.error("Could not persist the outbox: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [Item] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }
}
