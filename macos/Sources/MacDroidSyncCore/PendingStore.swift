import Foundation

/// Offline queue for the macOS to Android direction. Clipboard semantics are
/// "last one wins", so only the most recent value is kept. It is persisted so
/// that a copy made while the phone is away survives an app restart.
public final class PendingStore {
    public struct Item: Codable {
        public let text: String
        public let ts: Int64
    }

    private let url: URL
    private let queue = DispatchQueue(label: "\(Log.subsystem).pending")
    private var cached: Item?

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("pending.json")
        self.cached = load()
    }

    public var pending: Item? {
        queue.sync { cached }
    }

    public func store(text: String) {
        queue.sync {
            let item = Item(text: text, ts: Message.now())
            cached = item
            AppPaths.ensureSupportDirectory()
            do {
                try JSONEncoder().encode(item).write(to: url, options: .atomic)
            } catch {
                Log.error("Could not persist the pending clipboard: \(error.localizedDescription)")
            }
        }
    }

    public func clear() {
        queue.sync {
            cached = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func load() -> Item? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }
}
