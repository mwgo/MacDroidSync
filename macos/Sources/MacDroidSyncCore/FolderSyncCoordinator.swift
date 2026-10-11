import Foundation

/// Keeps folders on the phone and folders on this Mac the same, see PROTOCOL.md
/// section 10. The Mac decides: for each pair it asks the phone what its folder
/// holds, looks at its own, works out a `FolderSyncPlan` against what both held
/// after the last cycle and carries it out one file at a time.
///
/// Main actor only. A cycle runs when the phone connects, when it says a folder
/// changed, when a folder on the Mac shows a change, and every few minutes
/// besides; a cycle asked for while one runs follows it.
@MainActor
public final class FolderSyncCoordinator {

    public enum SyncError: LocalizedError {
        case noPhone
        case timeout(String)
        case disconnected
        case refused(String, String)
        case checksum(String)

        public var errorDescription: String? {
            switch self {
            case .noPhone: return "no phone connected"
            case .timeout(let type): return "the phone did not answer \(type)"
            case .disconnected: return "the phone disconnected"
            case .refused(let type, let reason): return "the phone refused \(type): \(reason)"
            case .checksum(let path): return "\(path) changed while it was copied"
            }
        }
    }

    public struct Status: Equatable {
        public var isRunning = false
        public var lastSync: Date?
        /// Why the last cycle did not finish, in words for the settings; nil when it did.
        public var lastError: String?
        /// What the phone said of the pair's folder when told of it.
        public var phone: FolderPairConfig?
    }

    public private(set) var pairs: [FolderPair] = []
    public private(set) var isConnected = false
    public private(set) var statuses: [String: Status] = [:]

    /// A status or the conflicts changed.
    public var onChange: (() -> Void)?
    /// A new entry in a pair's conflicts, for a notification.
    public var onConflict: ((FolderPair, FolderConflict) -> Void)?
    /// The cycle wrote into the Mac's folder of a pair: the paths, for the apps
    /// that show it.
    public var onMacWrote: ((FolderPair, [String]) -> Void)?

    private let transport: (String, FolderPayload, Data?) -> Bool
    private let directory: URL
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let settleDeletions: TimeInterval
    private let settleWrites: TimeInterval
    private let useTrash: Bool
    private let clock: () -> Date

    private var stores: [String: FolderSyncStore] = [:]
    private var waiting: [String: CheckedContinuation<FolderReply, Error>] = [:]
    private var queued: [String] = []
    private var running: String?
    private var again: Set<String> = []
    private var allowDeletionsOnce: Set<String> = []
    private var pollTimer: Timer?
    /// What each Mac folder looked like after the last cycle, so a look can tell a change.
    private var signatures: [String: [String: String]] = [:]

    public init(
        directory: URL = AppPaths.supportDirectory.appendingPathComponent("FolderSync", isDirectory: true),
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 300,
        settleDeletions: TimeInterval = 120,
        settleWrites: TimeInterval = 3,
        useTrash: Bool = true,
        clock: @escaping () -> Date = Date.init,
        transport: @escaping (String, FolderPayload, Data?) -> Bool
    ) {
        self.directory = directory
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.settleDeletions = settleDeletions
        self.settleWrites = settleWrites
        self.useTrash = useTrash
        self.clock = clock
        self.transport = transport
    }

    // MARK: - Pairs

    public func setPairs(_ pairs: [FolderPair]) {
        guard pairs != self.pairs else { return }
        let old = Set(self.pairs.map(\.id))
        self.pairs = pairs
        for pair in pairs {
            store(for: pair).use(macPath: pair.macPath, phonePath: pair.phonePath)
        }
        for id in old.subtracting(pairs.map(\.id)) {
            stores[id]?.removeAll()
            stores.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            signatures.removeValue(forKey: id)
        }
        if isConnected { _ = transport(MessageType.foldersConfig, config(), nil) }
        onChange?()
    }

    /// The pairs as the phone is told of them, in the handshake and after a change.
    public func config() -> FolderPayload {
        FolderPayload(pairs: pairs.filter(\.enabled).map { FolderPairConfig(id: $0.id, path: $0.phonePath) })
    }

    public func store(for pair: FolderPair) -> FolderSyncStore {
        if let store = stores[pair.id] { return store }
        let store = FolderSyncStore(pairId: pair.id, directory: directory)
        stores[pair.id] = store
        return store
    }

    public func status(of pair: FolderPair) -> Status { statuses[pair.id] ?? Status() }

    /// No cycle running or waiting to.
    public var isIdle: Bool { running == nil && queued.isEmpty }

    private func folder(for pair: FolderPair) -> LocalFolder {
        LocalFolder(root: pair.macURL, settleWrites: settleWrites, useTrash: useTrash)
    }

    // MARK: - Life cycle

    public func connected() {
        isConnected = true
        updatePolling()
        onChange?()
    }

    public func disconnected() {
        isConnected = false
        updatePolling()
        queued = []
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0.resume(throwing: SyncError.disconnected) }
        for id in statuses.keys { statuses[id]?.phone = nil }
        onChange?()
    }

    /// Anything the phone said about the folders.
    public func handle(_ reply: FolderReply) {
        switch reply.type {
        case MessageType.foldersConfig:
            for answer in reply.payload.pairs ?? [] {
                statuses[answer.id, default: Status()].phone = answer
            }
            onChange?()
            requestSync()
        case MessageType.folderChanged:
            requestSync(pairId: reply.payload.pair)
        default:
            guard let id = reply.payload.requestId, let continuation = waiting.removeValue(forKey: id) else { return }
            continuation.resume(returning: reply)
        }
    }

    /// Carries out the deletions held back as too many, on the next cycle.
    public func allowHeldDeletions(_ pair: FolderPair) {
        allowDeletionsOnce.insert(pair.id)
        store(for: pair).dismissConflicts(kind: FolderConflict.Kind.deletions)
        store(for: pair).dismissConflicts(kind: FolderConflict.Kind.empty)
        requestSync(pairId: pair.id)
        onChange?()
    }

    public func dismissConflict(_ pair: FolderPair, id: String) {
        store(for: pair).dismissConflict(id: id)
        onChange?()
    }

    /// A cycle for one pair, or for all of them.
    public func requestSync(pairId: String? = nil) {
        guard isConnected else { return }
        let ids = pairId.map { [$0] } ?? pairs.map(\.id)
        for id in ids where pairs.contains(where: { $0.id == id && $0.enabled }) {
            if running == id {
                again.insert(id)
            } else if !queued.contains(id) {
                queued.append(id)
            }
        }
        runNext()
    }

    /// Something in a Mac folder may have changed: a cycle follows if it did.
    public func macChanged(pairId: String) {
        guard isConnected, running != pairId, !queued.contains(pairId),
              let pair = pairs.first(where: { $0.id == pairId && $0.enabled }) else { return }
        let folder = self.folder(for: pair)
        let cache = store(for: pair).state.hashes
        Task { @MainActor in
            let scan = await Task.detached { folder.scan(cache: cache) }.value
            if self.signature(scan) != self.signatures[pairId] { self.requestSync(pairId: pairId) }
        }
    }

    /// A path an app says it changed: the pairs whose Mac folder holds it.
    public func macChanged(path: String) {
        let changed = URL(fileURLWithPath: path).standardizedFileURL.path
        for pair in pairs where pair.enabled {
            let root = pair.macURL.standardizedFileURL.path
            if changed == root || changed.hasPrefix(root.hasSuffix("/") ? root : root + "/") || root.hasPrefix(changed + "/") {
                requestSync(pairId: pair.id)
            }
        }
    }

    private func runNext() {
        guard running == nil, isConnected, !queued.isEmpty else { return }
        let id = queued.removeFirst()
        guard let pair = pairs.first(where: { $0.id == id }) else { return runNext() }
        running = id
        statuses[id, default: Status()].isRunning = true
        onChange?()
        Task { @MainActor in
            await self.cycle(pair)
            self.statuses[id, default: Status()].isRunning = false
            self.running = nil
            if self.again.remove(id) != nil, !self.queued.contains(id) { self.queued.append(id) }
            self.onChange?()
            self.runNext()
        }
    }

    private func updatePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isConnected else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
    }

    private func signature(_ scan: LocalFolder.Scan) -> [String: String] {
        var signature = Dictionary(scan.entries.map { (FolderRules.key($0.p), $0.h ?? "/") }, uniquingKeysWith: { a, _ in a })
        for key in scan.pending { signature[key] = "pending" }
        return signature
    }

    // MARK: - One cycle

    /// What a cycle works with: the pair, both lists by key, and the Mac's folder.
    private struct Cycle {
        let pair: FolderPair
        let store: FolderSyncStore
        let folder: LocalFolder
        var phone: [String: FolderEntry]
        var mac: [String: FolderEntry]
        var wroteOnMac: [String] = []
    }

    private func cycle(_ pair: FolderPair) async {
        let store = store(for: pair)
        if let phone = statuses[pair.id]?.phone, phone.ok == false {
            statuses[pair.id, default: Status()].lastError = "the phone cannot use \(pair.phonePath): \(phone.reason ?? "no reason")"
            return
        }
        do {
            let folder = self.folder(for: pair)
            let phoneEntries = try await manifest(pair)
            let cache = store.state.hashes
            let scan = await Task.detached { folder.scan(cache: cache) }.value
            if scan.missing {
                throw LocalFolderError.missing(pair.macPath)
            }
            var pending = scan.pending
            // iCloud may carry a rename over as a deletion first: a file gone
            // from a folder on iCloud Drive counts as gone only after a while.
            let now = clock()
            var missing: [String: Double] = [:]
            if scan.isUbiquitous {
                let present = Set(scan.entries.map { FolderRules.key($0.p) })
                for (key, base) in store.state.base where !base.isDirectory && !present.contains(key) && !pending.contains(key) {
                    let since = store.state.missingSince[key] ?? now.timeIntervalSince1970
                    missing[key] = since
                    if now.timeIntervalSince1970 - since < settleDeletions { pending.insert(key) }
                }
            }
            store.setMissing(missing)
            // Too large, or not readable on the phone just now: an empty checksum.
            for entry in phoneEntries where entry.s > FolderRules.maxFileSize || entry.h == "" {
                pending.insert(FolderRules.key(entry.p))
            }
            let allow = allowDeletionsOnce.remove(pair.id) != nil
            let plan = FolderSyncPlan.plan(base: store.state.base, phone: phoneEntries, mac: scan.entries, pending: pending, allowDeletions: allow)
            if let blocked = plan.blocked {
                let side = blocked == .phoneEmpty ? "the phone's folder" : "the Mac's folder"
                report(pair, FolderConflict(at: millis(now), kind: FolderConflict.Kind.empty, path: blocked == .phoneEmpty ? pair.phonePath : pair.macPath))
                statuses[pair.id, default: Status()].lastError = "\(side) is empty; allow it to delete everything on the other side"
                store.setHashes(scan.hashes)
                store.save()
                return
            }
            if !plan.steps.isEmpty { Log.info("Folder sync \(pair.name): \(plan.steps.count) step(s)") }
            var cycle = Cycle(
                pair: pair,
                store: store,
                folder: folder,
                phone: FolderSyncPlan.index(phoneEntries),
                mac: FolderSyncPlan.index(scan.entries)
            )
            var hashes = scan.hashes
            var failed: String?
            for step in plan.steps {
                guard isConnected else { throw SyncError.disconnected }
                do {
                    try await perform(step, in: &cycle, hashes: &hashes)
                } catch SyncError.disconnected {
                    throw SyncError.disconnected
                } catch let error as LocalFolderError {
                    if case .notEmpty = error { continue }
                    again.insert(pair.id)
                    Log.info("Folder sync \(pair.name): \(error.localizedDescription); next cycle")
                } catch {
                    failed = error.localizedDescription
                    Log.error("Folder sync \(pair.name) step \(step) failed: \(error.localizedDescription)")
                }
            }
            if plan.heldDeletions > 0 {
                report(pair, FolderConflict(at: millis(now), kind: FolderConflict.Kind.deletions, path: pair.macPath, count: plan.heldDeletions))
            }
            for path in scan.tooBig where !store.state.conflicts.contains(where: { $0.kind == FolderConflict.Kind.tooBig && $0.path == path }) {
                report(pair, FolderConflict(at: millis(now), kind: FolderConflict.Kind.tooBig, path: path))
            }
            store.setHashes(hashes)
            store.finishCycle(at: clock())
            store.clearWork()
            // What the Mac's folder should look like now: a file that changed
            // while the cycle ran differs from it, and brings another.
            let after = await Task.detached { [hashes] in folder.scan(cache: hashes) }.value
            var expected = signature(after)
            for (key, value) in expected where value != "pending" {
                if let base = store.state.base[key] { expected[key] = base.sha ?? "/" }
            }
            signatures[pair.id] = expected
            statuses[pair.id, default: Status()].lastSync = clock()
            statuses[pair.id, default: Status()].lastError = failed
            if !cycle.wroteOnMac.isEmpty { onMacWrote?(pair, cycle.wroteOnMac) }
        } catch {
            store.save()
            statuses[pair.id, default: Status()].lastError = error.localizedDescription
            Log.error("Folder sync \(pair.name) stopped: \(error.localizedDescription)")
        }
    }

    private func perform(_ step: FolderSyncPlan.Step, in cycle: inout Cycle, hashes: inout [String: FolderSyncStore.CachedHash]) async throws {
        let pair = cycle.pair
        let store = cycle.store
        switch step {
        case .makeDirOnMac(let key):
            guard let entry = cycle.phone[key] else { return }
            try cycle.folder.makeDirectory(entry.p)
            store.setBase(key, FolderBase(path: entry.p, sha: nil))
        case .makeDirOnPhone(let key):
            guard let entry = cycle.mac[key] else { return }
            let answer = try await ask(MessageType.folderPut, FolderPayload(pair: pair.id, path: entry.p, dir: true), refusalIsAnswer: true)
            if answer.ok { store.setBase(key, FolderBase(path: entry.p, sha: nil)) }
        case .same(let key):
            guard let entry = cycle.phone[key] ?? cycle.mac[key] else { return }
            store.setBase(key, FolderBase(path: entry.p, sha: entry.h))
        case .toMac(let key):
            try await toMac(key, in: &cycle, hashes: &hashes)
        case .toPhone(let key):
            try await toPhone(key, in: &cycle)
        case .conflict(let key):
            guard let phone = cycle.phone[key], let mac = cycle.mac[key] else { return }
            let copy = FolderRules.conflictPath(phone.p, date: clock())
            let moved = try await ask(MessageType.folderMove, FolderPayload(pair: pair.id, path: phone.p, to: copy, baseHash: phone.h), refusalIsAnswer: true)
            guard moved.ok else {
                Log.info("Folder sync \(pair.name): the phone left \(phone.p) for later (\(moved.reason ?? "no reason"))")
                return
            }
            cycle.phone.removeValue(forKey: key)
            store.setBase(key, nil)
            try await toPhone(key, in: &cycle)
            report(pair, FolderConflict(at: millis(clock()), kind: FolderConflict.Kind.edited, path: mac.p, copy: copy))
            again.insert(pair.id)
        case .moveOnMac(let from, let to):
            guard let source = cycle.mac[from], let target = cycle.phone[to], let sha = store.state.base[from]?.sha else { return }
            try cycle.folder.move(source.p, to: target.p, expected: sha)
            store.setBase(from, nil)
            store.setBase(to, FolderBase(path: target.p, sha: sha))
            if let cached = hashes.removeValue(forKey: from) { hashes[to] = cached }
            cycle.wroteOnMac.append(target.p)
            Log.info("Folder sync \(pair.name): \(source.p) moved to \(target.p) on the Mac")
        case .moveOnPhone(let from, let to):
            guard let source = cycle.phone[from], let target = cycle.mac[to], let sha = store.state.base[from]?.sha else { return }
            let answer = try await ask(MessageType.folderMove, FolderPayload(pair: pair.id, path: source.p, to: target.p, baseHash: sha), refusalIsAnswer: true)
            guard answer.ok else { return }
            store.setBase(from, nil)
            store.setBase(to, FolderBase(path: target.p, sha: sha))
            Log.info("Folder sync \(pair.name): \(source.p) moved to \(target.p) on the phone")
        case .restoreOnPhone(let key):
            try await toPhone(key, in: &cycle)
            report(pair, FolderConflict(at: millis(clock()), kind: FolderConflict.Kind.deletedOnPhone, path: cycle.mac[key]?.p ?? key))
        case .restoreOnMac(let key):
            try await toMac(key, in: &cycle, hashes: &hashes)
            report(pair, FolderConflict(at: millis(clock()), kind: FolderConflict.Kind.deletedOnMac, path: cycle.phone[key]?.p ?? key))
        case .deleteOnMac(let key):
            guard let entry = cycle.mac[key], let sha = store.state.base[key]?.sha else { return }
            try cycle.folder.delete(entry.p, expected: sha)
            store.setBase(key, nil)
            hashes.removeValue(forKey: key)
            cycle.wroteOnMac.append(entry.p)
            Log.info("Folder sync \(pair.name): \(entry.p) deleted on the Mac, as on the phone")
        case .deleteOnPhone(let key):
            guard let entry = cycle.phone[key], let sha = store.state.base[key]?.sha else { return }
            let answer = try await ask(MessageType.folderDelete, FolderPayload(pair: pair.id, path: entry.p, baseHash: sha), refusalIsAnswer: true)
            if answer.ok || answer.reason == "missing" {
                store.setBase(key, nil)
                Log.info("Folder sync \(pair.name): \(entry.p) deleted on the phone, as on the Mac")
            }
        case .removeDirOnMac(let key):
            guard let entry = cycle.mac[key] else { return }
            try cycle.folder.removeDirectory(entry.p)
            store.setBase(key, nil)
        case .removeDirOnPhone(let key):
            guard let entry = cycle.phone[key] else { return }
            let answer = try await ask(MessageType.folderDelete, FolderPayload(pair: pair.id, path: entry.p, dir: true), refusalIsAnswer: true)
            if answer.ok || answer.reason == "missing" { store.setBase(key, nil) }
        case .forget(let key):
            store.setBase(key, nil)
        }
    }

    // MARK: - Phone to Mac

    private func toMac(_ key: String, in cycle: inout Cycle, hashes: inout [String: FolderSyncStore.CachedHash]) async throws {
        guard let entry = cycle.phone[key], let expectedSha = entry.h else { return }
        let pair = cycle.pair
        let file = cycle.store.freshWorkFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = try await download(pair, path: entry.p, to: file)
        guard sha == expectedSha else { throw SyncError.checksum(entry.p) }
        let path = cycle.mac[key]?.p ?? entry.p
        try cycle.folder.install(file, at: path, expected: cycle.mac[key]?.h)
        cycle.store.setBase(key, FolderBase(path: path, sha: sha))
        let values = try? cycle.folder.url(path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let date = values?.contentModificationDate {
            hashes[key] = FolderSyncStore.CachedHash(size: Int64(values?.fileSize ?? 0), modified: millis(date), sha: sha)
        }
        cycle.wroteOnMac.append(path)
        Log.info("Folder sync \(pair.name): \(path) \(cycle.mac[key] == nil ? "added to" : "updated on") the Mac")
    }

    private func download(_ pair: FolderPair, path: String, to file: URL) async throws -> String {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            let answer = try await ask(MessageType.folderGet, FolderPayload(pair: pair.id, path: path, offset: offset))
            let piece = answer.data ?? Data()
            try handle.write(contentsOf: piece)
            offset += Int64(piece.count)
            let total = answer.payload.total ?? offset
            if offset >= total { break }
            if piece.isEmpty { throw SyncError.refused(MessageType.folderGet, "empty piece") }
        }
        try handle.close()
        return try LocalFolder(root: file.deletingLastPathComponent()).hash(file)
    }

    // MARK: - Mac to phone

    private func toPhone(_ key: String, in cycle: inout Cycle) async throws {
        guard let entry = cycle.mac[key] else { return }
        let pair = cycle.pair
        let file = cycle.store.freshWorkFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = try cycle.folder.snapshot(entry.p, into: file)
        let path = cycle.phone[key]?.p ?? entry.p
        let answer = try await upload(pair, file: file, sha: sha, path: path, baseHash: cycle.phone[key]?.h)
        // Refused while the file is open with changes, or changed meanwhile:
        // the phone says when it has saved it, and that brings the next cycle.
        guard answer.ok else {
            Log.info("Folder sync \(pair.name): the phone left \(path) for later (\(answer.reason ?? "no reason"))")
            return
        }
        cycle.store.setBase(key, FolderBase(path: path, sha: sha))
        Log.info("Folder sync \(pair.name): \(path) \(cycle.phone[key] == nil ? "added to" : "updated on") the phone")
    }

    /// Sends a file in pieces; the last answer, or the first refusal.
    private func upload(_ pair: FolderPair, file: URL, sha: String, path: String, baseHash: String?) async throws -> FolderReply {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        var offset: Int64 = 0
        while true {
            let piece = try handle.read(upToCount: FolderRules.chunk) ?? Data()
            let answer = try await ask(
                MessageType.folderPut,
                FolderPayload(pair: pair.id, path: path, offset: offset, total: total, sha256: sha, baseHash: baseHash),
                data: piece,
                refusalIsAnswer: true
            )
            offset += Int64(piece.count)
            if !answer.ok || offset >= total { return answer }
            if piece.isEmpty { throw SyncError.refused(MessageType.folderPut, "short file") }
        }
    }

    // MARK: - Asking the phone

    private func manifest(_ pair: FolderPair) async throws -> [FolderEntry] {
        var entries: [FolderEntry] = []
        var cursor: Int?
        repeat {
            let answer = try await ask(MessageType.folderManifest, FolderPayload(pair: pair.id, cursor: cursor))
            entries += (answer.payload.entries ?? []).filter { FolderRules.isValid(path: $0.p) }
            cursor = answer.payload.cursor
        } while cursor != nil
        return entries
    }

    /// Sends one request and waits for its answer. A refusal throws unless
    /// `refusalIsAnswer`, for the requests whose refusal the caller acts on.
    private func ask(_ type: String, _ payload: FolderPayload, data: Data? = nil, refusalIsAnswer: Bool = false) async throws -> FolderReply {
        guard isConnected else { throw SyncError.noPhone }
        var payload = payload
        let id = UUID().uuidString
        payload.requestId = id
        let timeout = timeout
        let reply: FolderReply = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            guard transport(type, payload, data) else {
                waiting.removeValue(forKey: id)
                continuation.resume(throwing: SyncError.noPhone)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let late = self?.waiting.removeValue(forKey: id) { late.resume(throwing: SyncError.timeout(type)) }
            }
        }
        if !reply.ok && !refusalIsAnswer { throw SyncError.refused(type, reply.reason ?? "no reason") }
        return reply
    }

    private func report(_ pair: FolderPair, _ conflict: FolderConflict) {
        store(for: pair).addConflict(conflict)
        Log.info("Folder sync \(pair.name) conflict (\(conflict.kind)): \(conflict.path)")
        onConflict?(pair, conflict)
        onChange?()
    }

    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
