import Foundation

/// The Wi-Fi networks on which this Mac does not lock itself.
///
/// A network is stored by the identity `CurrentNetwork` reports and by nothing
/// else. There is deliberately no name: macOS reveals the name of the joined
/// network only to an app allowed to use your location, and a name typed by hand
/// would be decoration - the decision never looks at it. So the list shows the
/// identity itself, which is the thing actually being compared.
///
/// This list is a convenience, not a security boundary: it trusts the network you
/// joined. Anyone able to put your Mac on a network you have marked safe can also
/// stop it locking itself.
public final class SafeNetworkStore {

    public struct Network: Codable, Equatable, Identifiable {
        public let id: String
        public let ts: Int64

        public init(id: String, ts: Int64) {
            self.id = id
            self.ts = ts
        }
    }

    private let url: URL
    private let queue = DispatchQueue(label: "\(Log.subsystem).safe-networks")
    private var networks: [Network]

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("safe-networks.json")
        self.networks = Self.load(from: self.url)
    }

    /// Everything on the list, oldest first.
    public var all: [Network] {
        queue.sync { networks }
    }

    public var count: Int {
        queue.sync { networks.count }
    }

    /// The whole decision this feature makes.
    ///
    /// A missing identity is never safe. That single line is what makes Wi-Fi
    /// switched off, a Mac on Ethernet and an unreadable network all keep the
    /// auto lock running instead of quietly disabling it.
    public func isSafe(_ profileID: String?) -> Bool {
        guard let profileID, !profileID.isEmpty else { return false }
        return queue.sync { networks.contains { $0.id == profileID } }
    }

    /// Adding a network already on the list changes nothing, so pressing the
    /// button twice cannot grow a duplicate.
    public func add(id: String) {
        guard !id.isEmpty else { return }
        queue.sync {
            guard !networks.contains(where: { $0.id == id }) else { return }
            networks.append(Network(id: id, ts: Message.now()))
            persist()
            Log.info("Safe network \(CurrentNetwork.shortForm(id)) added")
        }
    }

    public func remove(id: String) {
        queue.sync {
            guard let index = networks.firstIndex(where: { $0.id == id }) else { return }
            networks.remove(at: index)
            persist()
            Log.info("Safe network \(CurrentNetwork.shortForm(id)) removed")
        }
    }

    // MARK: - Persistence

    private func persist() {
        AppPaths.ensureSupportDirectory()
        do {
            if networks.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try JSONEncoder().encode(networks).write(to: url, options: .atomic)
            }
        } catch {
            Log.error("Could not persist the safe networks: \(error.localizedDescription)")
        }
    }

    /// A file that cannot be read comes back as an empty list, which means every
    /// network counts as untrusted and the Mac keeps locking. The opposite
    /// default would turn a damaged file into a silently disabled auto lock.
    private static func load(from url: URL) -> [Network] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Network].self, from: data) else {
            Log.error("The safe network list at \(url.path) is unreadable, treating every network as unsafe")
            return []
        }
        return decoded
    }
}
