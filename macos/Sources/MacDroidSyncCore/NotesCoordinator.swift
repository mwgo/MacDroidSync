import Foundation
import NotesMDKit

/// Keeps the phone's notes and the folder of notes on this Mac the same, see
/// PROTOCOL.md section 10. The Mac decides: it asks the phone for its notes,
/// lists the folder, works out a `NotesSyncPlan` and carries it out one note
/// at a time.
///
/// Main actor only. A cycle runs when the phone connects, when it says a note
/// changed, when the folder shows a change, and when the sync is switched on;
/// a cycle asked for while one runs follows it.
@MainActor
public final class NotesCoordinator {

    public enum SyncError: LocalizedError {
        case noPhone
        case timeout(String)
        case disconnected
        case refused(String, String)

        public var errorDescription: String? {
            switch self {
            case .noPhone: return "no phone connected"
            case .timeout(let type): return "the phone did not answer \(type)"
            case .disconnected: return "the phone disconnected"
            case .refused(let type, let reason): return "the phone refused \(type): \(reason)"
            }
        }
    }

    public let store: NotesSyncStore
    public private(set) var library: NoteLibrary
    private let transport: (String, NotesPayload, Data?) -> Bool
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let clock: () -> Date

    /// The conflicts or the status changed.
    public var onChange: (() -> Void)?
    /// A new entry in the conflicts list, for a notification.
    public var onConflict: ((NotesConflict) -> Void)?

    public private(set) var isEnabled = false
    public private(set) var isConnected = false
    public private(set) var isRunning = false
    public private(set) var lastSync: Date?
    /// Why the last cycle did not finish, in words for the settings; nil when it did.
    public private(set) var lastError: String?

    private var waiting: [String: CheckedContinuation<NotesReply, Error>] = [:]
    private var again = false
    private var allowDeletionsOnce = false
    private var pollTimer: Timer?
    /// What the folder looked like after the last cycle, so a look can tell a change.
    private var macSignature: [String: String] = [:]

    public init(
        store: NotesSyncStore,
        library: NoteLibrary,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 60,
        clock: @escaping () -> Date = Date.init,
        transport: @escaping (String, NotesPayload, Data?) -> Bool
    ) {
        self.store = store
        self.library = library
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.clock = clock
        self.transport = transport
    }

    // MARK: - Life cycle

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        updatePolling()
        if enabled { requestSync() }
        onChange?()
    }

    /// Another folder of notes: the pairs of the old one mean nothing here.
    public func setLibrary(_ library: NoteLibrary, root: String) {
        self.library = library
        store.use(root: root)
        macSignature = [:]
        requestSync()
    }

    public func connected() {
        isConnected = true
        updatePolling()
        requestSync()
    }

    public func disconnected() {
        isConnected = false
        updatePolling()
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0.resume(throwing: SyncError.disconnected) }
        onChange?()
    }

    /// Carries out the deletions held back as too many, on the next cycle.
    public func allowHeldDeletions() {
        allowDeletionsOnce = true
        store.state.conflicts.filter { $0.kind == NotesConflict.Kind.deletions }.forEach { store.dismissConflict(id: $0.id) }
        requestSync()
        onChange?()
    }

    public func dismissConflict(id: String) {
        store.dismissConflict(id: id)
        store.pruneAssets()
        onChange?()
    }

    /// Anything the phone said about notes.
    public func handle(_ reply: NotesReply) {
        if reply.type == MessageType.notesChanged {
            requestSync()
            return
        }
        guard let id = reply.payload.requestId, let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(returning: reply)
    }

    public func requestSync() {
        guard isEnabled, isConnected else { return }
        if isRunning {
            again = true
            return
        }
        isRunning = true
        onChange?()
        Task { @MainActor in
            await self.cycle()
            self.isRunning = false
            self.onChange?()
            if self.again {
                self.again = false
                self.requestSync()
            }
        }
    }

    /// Something in the folder may have changed: a cycle follows if it did.
    public func folderChanged() {
        Task { @MainActor in await self.poll() }
    }

    private func updatePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isEnabled, isConnected else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    private func poll() async {
        guard isEnabled, isConnected, !isRunning else { return }
        guard let list = try? await library.list() else { return }
        if signature(list) != macSignature { requestSync() }
    }

    /// What the folder looks like to the sync: a note settling counts too, so
    /// that the cycle after it settles - gone for good, or back - is not missed.
    private func signature(_ list: LibraryList) -> [String: String] {
        var signature = Dictionary(list.notes.map { ($0.id, "\($0.hash)|\($0.folder)") }, uniquingKeysWith: { a, _ in a })
        for id in list.pending { signature[id] = "pending" }
        return signature
    }

    // MARK: - One cycle

    private func cycle() async {
        do {
            let manifest = try await ask(MessageType.notesManifest, NotesPayload())
            var phone = manifest.payload.notes ?? []
            let phoneFolders = manifest.payload.folders ?? []
            var list = try await library.list()
            store.remapMacIds { list.merged[$0] ?? $0 }
            let folders = NotesSyncPlan.folders(
                known: store.state.folders.map(Set.init),
                phone: phoneFolders,
                mac: try await library.folders()
            )
            for folder in folders.createOnMac { try await library.ensureFolder(folder) }
            try await pairTheSame(phone: phone, mac: list.notes)

            // A note iCloud is still moving is left alone until it settles.
            let unsettled = store.pairs.filter { list.pending.contains($0.macId) }
            let skipPhone = Set(unsettled.map(\.androidId))
            let skipMac = Set(unsettled.map(\.macId))
            phone.removeAll { skipPhone.contains($0.id) }
            list.notes.removeAll { skipMac.contains($0.id) }
            let pairs = store.pairs.filter { !skipPhone.contains($0.androidId) }

            let plan = NotesSyncPlan.plan(pairs: pairs, phone: phone, mac: list.notes, allowDeletions: allowDeletionsOnce)
            allowDeletionsOnce = false
            if !plan.steps.isEmpty { Log.info("Notes sync: \(plan.steps.count) step(s)") }
            let phoneById = Dictionary(phone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let macById = Dictionary(list.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var failed: String?
            for step in plan.steps {
                guard isConnected, isEnabled else { break }
                do {
                    try await perform(step, phone: phoneById, mac: macById)
                } catch SyncError.disconnected {
                    throw SyncError.disconnected
                } catch {
                    failed = error.localizedDescription
                    Log.error("Notes sync step \(step) failed: \(error.localizedDescription)")
                }
            }
            if plan.heldDeletions > 0 { holdDeletions(plan.heldDeletions) }
            let waiting = try await deleteFolders(folders)
            try await finish(waiting: waiting)
            macSignature = signature(try await library.list())
            store.clearWork()
            lastSync = clock()
            lastError = failed
        } catch {
            lastError = error.localizedDescription
            Log.error("Notes sync stopped: \(error.localizedDescription)")
        }
    }

    private func perform(_ step: NotesSyncPlan.Step, phone: [String: NoteEntry], mac: [String: MacNoteInfo]) async throws {
        switch step {
        case .pushToMac(let androidId):
            guard let pair = store.pair(androidId: androidId), let entry = phone[androidId] else { return }
            if entry.hash == pair.androidHash {
                try await moveOnMac(pair, to: entry.folder)
            } else {
                try await push(androidId: androidId, into: pair.macId, keeping: pair)
            }
        case .createOnMac(let androidId):
            try await push(androidId: androidId, into: nil, keeping: nil)
        case .pullFromMac(let macId):
            guard let pair = store.pair(macId: macId), let entry = phone[pair.androidId], let note = mac[macId] else { return }
            if note.hash == pair.macHash {
                try await moveOnPhone(pair, to: note)
            } else {
                try await pull(macId, into: pair.androidId, baseHash: entry.hash, keeping: pair)
            }
        case .both(let androidId):
            guard let pair = store.pair(androidId: androidId), let entry = phone[androidId], let note = mac[pair.macId] else { return }
            let phoneEdited = entry.hash != pair.androidHash
            let macEdited = note.hash != pair.macHash
            switch (phoneEdited, macEdited) {
            case (true, true):
                try await conflict(pair: pair, entry: entry, mac: note)
            case (true, false):
                // The phone's text changed, and a folder on the Mac: the text goes into the Mac's folder.
                try await push(androidId: androidId, into: pair.macId, keeping: pair, folder: note.folder == pair.macFolder ? nil : note.folder)
                if note.folder != pair.macFolder, let moved = store.pair(androidId: androidId) {
                    try await moveOnPhone(moved, to: try await library.read(id: moved.macId).info)
                }
            case (false, true):
                // Edited on the Mac, moved on the phone: the text comes, the phone's folder stays.
                try await pull(pair.macId, into: androidId, baseHash: entry.hash, keeping: pair, folder: entry.folder)
                if let moved = store.pair(androidId: androidId) { try await moveOnMac(moved, to: entry.folder) }
            case (false, false):
                // Moved on both sides: the Mac's folder wins.
                try await moveOnPhone(pair, to: note)
            }
        case .createOnPhone(let macId):
            try await pull(macId, into: nil, baseHash: nil, keeping: nil)
        case .deleteOnMac(let macId):
            guard let pair = store.pair(macId: macId) else { return }
            try await library.delete(id: macId)
            store.removePair(androidId: pair.androidId)
            Log.info("Deleted \"\(mac[macId]?.name ?? macId)\" on the Mac, as on the phone")
        case .deleteOnPhone(let androidId):
            guard let pair = store.pair(androidId: androidId) else { return }
            let answer = try await ask(MessageType.notesDelete, NotesPayload(id: androidId, baseHash: pair.androidHash), refusalIsAnswer: true)
            if answer.ok {
                store.removePair(androidId: androidId)
                Log.info("Deleted \"\(phone[androidId]?.title ?? androidId)\" on the phone, as on the Mac")
            }
        case .restoreOnPhone(let macId):
            guard let pair = store.pair(macId: macId) else { return }
            store.removePair(androidId: pair.androidId)
            let note = try await pull(macId, into: nil, baseHash: nil, keeping: nil)
            report(NotesConflict(
                at: now(),
                kind: NotesConflict.Kind.deletedOnPhone,
                title: mac[macId]?.name ?? "",
                macMarkdown: note.map(forDisplay)
            ))
        case .restoreOnMac(let androidId):
            guard let pair = store.pair(androidId: androidId) else { return }
            store.removePair(androidId: androidId)
            let doc = try await push(androidId: androidId, into: nil, keeping: nil)
            report(NotesConflict(
                at: now(),
                kind: NotesConflict.Kind.deletedOnMac,
                title: phone[androidId]?.title ?? pair.macFolder,
                phoneMarkdown: doc.map { forDisplay($0.markdown, assets: assetMap($0)) }
            ))
        case .forget(let androidId):
            store.removePair(androidId: androidId)
        }
    }

    // MARK: - Phone to Mac

    /// Writes the phone's note into the folder, a new one when `macId` is nil,
    /// and records the pair as it now stands. Returns the note as the phone sent it.
    @discardableResult
    private func push(androidId: String, into macId: String?, keeping pair: NotesPair?, folder chosen: String? = nil) async throws -> NoteDoc? {
        let answer = try await ask(MessageType.notesGet, NotesPayload(id: androidId), refusalIsAnswer: true)
        guard answer.ok, let doc = answer.payload.note else { return nil }
        // Only what the Mac does not have as it is comes over.
        let have: [String: String]
        if let macId, let local = try? await library.read(id: macId) {
            have = Dictionary(local.assets.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        } else {
            have = [:]
        }
        var files: [String: URL] = [:]
        for asset in doc.assets where have[asset.path] != asset.sha256 {
            if !store.hasAsset(sha256: asset.sha256) { try await download(asset) }
            if let url = store.assetURL(sha256: asset.sha256) { files[asset.path] = url }
        }
        let folder = chosen ?? (doc.folder.isEmpty ? "Notes" : doc.folder)
        let written: MacNoteInfo
        do {
            written = try await library.write(id: macId, folder: folder, markdown: doc.markdown, assets: files, baseHash: pair?.macHash)
        } catch let error as FolderStoreErrorConvertible where error.isChanged {
            Log.info("Notes sync: the note on the Mac changed meanwhile; next cycle")
            again = true
            return nil
        }
        store.setPair(NotesPair(
            androidId: doc.id,
            macId: written.id,
            androidHash: doc.hash,
            androidFolder: doc.folder,
            macHash: written.hash,
            macFolder: written.folder,
            phoneAssets: assetMap(doc)
        ))
        Log.info("Notes sync: \"\(written.name)\" \(macId == nil ? "added to" : "updated on") the Mac")
        return doc
    }

    // MARK: - Mac to phone

    /// Writes a note of the Mac onto the phone, a new one when `androidId` is
    /// nil. Returns the note as sent, or nil when the phone left it for later:
    /// it changed there in between, or it is open being edited.
    @discardableResult
    private func pull(
        _ macId: String,
        into androidId: String?,
        baseHash: String?,
        keeping pair: NotesPair?,
        folder chosen: String? = nil
    ) async throws -> LocalNote? {
        let note = try await library.read(id: macId)
        let folder = chosen ?? note.info.folder
        let known = pair?.phoneAssets ?? [:]
        var put = NotesPayload(id: androidId, folder: folder, markdown: note.markdown, baseHash: baseHash)
        // A file new to the phone goes first, as the note needs it. One that
        // replaces a file the phone has at the same path goes after: before,
        // it would change the phone's hash under the `baseHash` of the put.
        let replaced = note.assets.filter { known[$0.path] != nil && known[$0.path] != $0.sha256 }
        for asset in note.assets where known[asset.path] == nil {
            try await upload(asset.url, path: asset.path, sha: asset.sha256)
        }
        var answer = try await ask(MessageType.notesPut, put, refusalIsAnswer: true)
        if !answer.ok, answer.reason == "missing asset" {
            // The phone lost a picture it once had; send every one this note uses.
            for asset in note.assets where known[asset.path] == asset.sha256 {
                try await upload(asset.url, path: asset.path, sha: asset.sha256)
            }
            answer = try await ask(MessageType.notesPut, put, refusalIsAnswer: true)
        }
        guard answer.ok, let id = answer.payload.id, var hash = answer.payload.hash else {
            Log.info("Notes sync: the phone left \"\(note.info.name)\" for later (\(answer.reason ?? "no reason"))")
            return nil
        }
        put.id = id
        if !replaced.isEmpty {
            for asset in replaced { try await upload(asset.url, path: asset.path, sha: asset.sha256) }
            // What the phone's hash is now, worked out as it does.
            hash = NoteHash.hash(markdown: note.markdown, assets: note.assets.map { ($0.path, $0.sha256) })
        }
        store.setPair(NotesPair(
            androidId: id,
            macId: macId,
            androidHash: hash,
            androidFolder: folder,
            macHash: note.info.hash,
            macFolder: note.info.folder,
            phoneAssets: Dictionary(note.assets.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        ))
        Log.info("Notes sync: \"\(note.info.name)\" \(androidId == nil ? "added to" : "updated on") the phone")
        return note
    }

    /// The phone moved the note to another folder and changed nothing else.
    private func moveOnMac(_ pair: NotesPair, to folder: String) async throws {
        let moved = try await library.move(id: pair.macId, folder: folder)
        var pair = pair
        pair.androidFolder = folder
        pair.macFolder = moved.folder
        pair.macHash = moved.hash
        store.setPair(pair)
        Log.info("Notes sync: \"\(moved.name)\" moved to \(folder) on the Mac")
    }

    /// The note was moved on the Mac and nothing else changed.
    private func moveOnPhone(_ pair: NotesPair, to note: MacNoteInfo) async throws {
        let answer = try await ask(MessageType.notesPut, NotesPayload(id: pair.androidId, folder: note.folder), refusalIsAnswer: true)
        guard answer.ok else { return }
        var pair = pair
        pair.androidFolder = note.folder
        pair.macFolder = note.folder
        pair.macHash = note.hash
        if let hash = answer.payload.hash { pair.androidHash = hash }
        store.setPair(pair)
        Log.info("Notes sync: \"\(note.name)\" moved to \(note.folder) on the phone")
    }

    // MARK: - Conflicts

    /// Changed on both sides. As agreed: the version on the Mac stays the note,
    /// and the phone's becomes a copy with a word added to its title, on both
    /// sides once the next cycle has taken the copy to the Mac.
    private func conflict(pair: NotesPair, entry: NoteEntry, mac note: MacNoteInfo) async throws {
        let original = try await ask(MessageType.notesGet, NotesPayload(id: pair.androidId))
        guard let doc = original.payload.note else { return }
        for asset in doc.assets where !store.hasAsset(sha256: asset.sha256) { try await download(asset) }
        let suffix = " (Android, \(Self.stamp.string(from: clock())))"
        let copy = try await ask(MessageType.notesCopy, NotesPayload(id: pair.androidId, titleSuffix: suffix))
        guard copy.payload.id != nil else { return }
        let written = try await pull(note.id, into: pair.androidId, baseHash: doc.hash, keeping: pair)
        report(NotesConflict(
            at: now(),
            kind: NotesConflict.Kind.edited,
            title: note.name,
            phoneMarkdown: forDisplay(doc.markdown, assets: assetMap(doc)),
            macMarkdown: written.map(forDisplay),
            copyTitle: Self.title(of: doc.markdown) + suffix
        ))
        again = true
    }

    private func holdDeletions(_ count: Int) {
        guard !store.conflicts.contains(where: { $0.kind == NotesConflict.Kind.deletions && $0.count == count }) else { return }
        report(NotesConflict(at: now(), kind: NotesConflict.Kind.deletions, title: "\(count) deletions", count: count))
    }

    private func report(_ conflict: NotesConflict) {
        store.addConflict(conflict)
        Log.info("Notes conflict (\(conflict.kind)): \(conflict.title)")
        onConflict?(conflict)
        onChange?()
    }

    /// A version for the conflicts window: pictures point at the store's copies.
    private func forDisplay(_ markdown: String, assets: [String: String]) -> String {
        markdown.components(separatedBy: "\n").map { line in
            guard let image = Markdown.parseImage(line), let sha = assets[image.path] else { return line }
            return "![](asset:\(sha))"
        }.joined(separator: "\n")
    }

    private func forDisplay(_ note: LocalNote) -> String {
        var assets: [String: String] = [:]
        for asset in note.assets where asset.path.hasPrefix("images/") {
            if let data = try? Data(contentsOf: asset.url) { assets[asset.path] = store.storeAsset(data) }
        }
        return forDisplay(note.markdown, assets: assets)
    }

    private func assetMap(_ doc: NoteDoc) -> [String: String] {
        Dictionary(doc.assets.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Folders and the first sync

    /// A folder deleted on one side goes on the other once the notes in it are
    /// gone, which the steps before saw to. Returns those still waiting, a
    /// folder that has notes left in it, on the phone and on the Mac.
    private func deleteFolders(_ folders: NotesSyncPlan.Folders) async throws -> (phone: Set<String>, mac: Set<String>) {
        var phone = Set<String>()
        var mac = Set<String>()
        for folder in folders.deleteOnPhone {
            let answer = try await ask(MessageType.notesFolderDelete, NotesPayload(folder: folder), refusalIsAnswer: true)
            if answer.ok {
                Log.info("Notes sync: folder \"\(folder)\" deleted on the phone")
            } else {
                phone.insert(folder)
            }
        }
        for folder in folders.deleteOnMac {
            if try await library.deleteFolder(folder) {
                Log.info("Notes sync: folder \"\(folder)\" deleted on the Mac")
            } else {
                mac.insert(folder)
            }
        }
        return (phone, mac)
    }

    /// Remembers the folders both sides have now, with the deletions still to
    /// carry out, and tells the phone which of its notes the Mac holds as they are.
    private func finish(waiting: (phone: Set<String>, mac: Set<String>)) async throws {
        let manifest = try await ask(MessageType.notesManifest, NotesPayload())
        let phone = Set(manifest.payload.folders ?? [])
        let mac = Set(try await library.folders())
        store.setFolders(phone.intersection(mac).union(waiting.phone.intersection(phone)).union(waiting.mac.intersection(mac)))
        let entries = manifest.payload.notes ?? []
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let synced = store.pairs.compactMap { pair -> NoteEntry? in
            guard let entry = byId[pair.androidId], !entry.isDeleted, entry.hash == pair.androidHash else { return nil }
            return NoteEntry(id: entry.id, folder: entry.folder, title: "", modified: entry.modified, hash: entry.hash)
        }
        _ = try await ask(MessageType.notesSynced, NotesPayload(notes: synced), refusalIsAnswer: true)
    }

    /// The same note on both sides before they were ever synced becomes a pair
    /// instead of two copies of each: the same hash, or the same folder, title
    /// and words.
    private func pairTheSame(phone: [NoteEntry], mac: [MacNoteInfo]) async throws {
        let pairedPhone = Set(store.pairs.map(\.androidId))
        var freeMac = mac.filter { store.pair(macId: $0.id) == nil }
        guard !freeMac.isEmpty else { return }
        for entry in phone where !entry.isDeleted && !pairedPhone.contains(entry.id) {
            var match = freeMac.first { $0.hash == entry.hash }
            if match == nil, let candidate = freeMac.first(where: {
                $0.folder == entry.folder && Markdown.plain($0.name) == Markdown.plain(entry.title)
            }) {
                let answer = try await ask(MessageType.notesGet, NotesPayload(id: entry.id), refusalIsAnswer: true)
                let local = try await library.read(id: candidate.id)
                if let doc = answer.payload.note, Markdown.contentKey(doc.markdown) == Markdown.contentKey(local.markdown) {
                    match = candidate
                }
            }
            guard let match else { continue }
            freeMac.removeAll { $0.id == match.id }
            // Paired as they are: what differs counts as changed on the phone, so the phone's version goes to the Mac.
            store.setPair(NotesPair(
                androidId: entry.id,
                macId: match.id,
                androidHash: match.hash == entry.hash ? entry.hash : "",
                androidFolder: entry.folder,
                macHash: match.hash,
                macFolder: match.folder
            ))
            Log.info("Notes sync: \"\(entry.title)\" was already on both sides")
        }
    }

    // MARK: - Pictures and files

    private func download(_ asset: NoteAsset) async throws {
        var data = Data()
        var offset: Int64 = 0
        repeat {
            let answer = try await ask(MessageType.notesAssetGet, NotesPayload(path: asset.path, offset: offset))
            guard let piece = answer.data, !piece.isEmpty || answer.payload.total == offset else {
                throw SyncError.refused(MessageType.notesAssetGet, "empty piece")
            }
            data.append(piece)
            offset += Int64(piece.count)
            if piece.isEmpty { break }
            if offset >= answer.payload.total ?? 0 { break }
        } while true
        let sha = store.storeAsset(data)
        if sha != asset.sha256 { Log.info("Notes sync: \(asset.path) changed while it was read") }
    }

    private func upload(_ url: URL, path: String, sha: String) async throws {
        guard let data = try? Data(contentsOf: url) else { return }
        let chunk = Self.assetChunk
        var offset = 0
        repeat {
            let end = min(offset + chunk, data.count)
            _ = try await ask(
                MessageType.notesAssetPut,
                NotesPayload(path: path, offset: Int64(offset), total: Int64(data.count), sha256: notesSHA256(data)),
                data: data.subdata(in: offset..<end)
            )
            offset = end
        } while offset < data.count
    }

    // MARK: - Asking the phone

    /// Sends one request and waits for its answer. A refusal throws unless
    /// `refusalIsAnswer`, for the requests whose refusal the caller acts on.
    private func ask(_ type: String, _ payload: NotesPayload, data: Data? = nil, refusalIsAnswer: Bool = false) async throws -> NotesReply {
        guard isConnected else { throw SyncError.noPhone }
        var payload = payload
        let id = UUID().uuidString
        payload.requestId = id
        let timeout = timeout
        let reply: NotesReply = try await withCheckedThrowingContinuation { continuation in
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

    private func now() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    /// Raw bytes per notes-asset piece; as on the phone.
    static let assetChunk = 1024 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static func title(of markdown: String) -> String {
        let first = markdown.components(separatedBy: "\n").first ?? ""
        return first.hasPrefix("# ") ? String(first.dropFirst(2)) : first
    }
}

/// A library's refusal to write over a change the sync has not seen.
public protocol FolderStoreErrorConvertible: Error {
    var isChanged: Bool { get }
}
