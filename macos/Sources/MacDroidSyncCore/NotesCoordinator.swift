import Foundation

/// Keeps the phone's notes and Notes on this Mac the same, see PROTOCOL.md
/// section 10. The Mac decides: it asks the phone for its notes, reads Notes,
/// works out a `NotesSyncPlan` and carries it out one note at a time.
///
/// Main actor only. A cycle runs when the phone connects, when it says a note
/// changed, when Notes shows a change, and when the sync is switched on; a
/// cycle asked for while one runs follows it.
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
    private let library: NotesLibrary
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
    /// What Notes looked like after the last cycle, so a poll can tell a change.
    private var macSignature: [String: String] = [:]

    public init(
        store: NotesSyncStore,
        library: NotesLibrary,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 10,
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

    private func updatePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isEnabled, isConnected else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    /// Notes says nothing when a note changes, so its list is looked at now and then.
    private func poll() async {
        guard isEnabled, isConnected, !isRunning else { return }
        guard let notes = try? await library.list() else { return }
        if signature(notes) != macSignature { requestSync() }
    }

    private func signature(_ notes: [MacNoteInfo]) -> [String: String] {
        Dictionary(notes.map { ($0.id, "\($0.modified)|\($0.folder)") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - One cycle

    private func cycle() async {
        do {
            let manifest = try await ask(MessageType.notesManifest, NotesPayload())
            let phone = manifest.payload.notes ?? []
            let phoneFolders = manifest.payload.folders ?? []
            var mac = try await library.list()
            try await createFolders(phoneFolders, existing: Set(mac.map(\.folder)))
            try await pairTheSame(phone: phone, mac: mac)

            let plan = NotesSyncPlan.plan(pairs: store.pairs, phone: phone, mac: mac, allowDeletions: allowDeletionsOnce)
            allowDeletionsOnce = false
            if !plan.steps.isEmpty { Log.info("Notes sync: \(plan.steps.count) step(s)") }
            let phoneById = Dictionary(phone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let macById = Dictionary(mac.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var failed: String?
            for step in plan.steps {
                guard isConnected, isEnabled else { break }
                do {
                    try await perform(step, phone: phoneById, mac: macById)
                } catch SyncError.disconnected {
                    throw SyncError.disconnected
                } catch NotesLibraryError.notAuthorized {
                    throw NotesLibraryError.notAuthorized
                } catch {
                    failed = error.localizedDescription
                    Log.error("Notes sync step \(step) failed: \(error.localizedDescription)")
                }
            }
            if plan.heldDeletions > 0 { holdDeletions(plan.heldDeletions) }
            mac = try await library.list()
            macSignature = signature(mac)
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
            guard let pair = store.pair(androidId: androidId) else { return }
            try await push(androidId: androidId, into: pair.macId, keeping: pair)
        case .createOnMac(let androidId):
            try await push(androidId: androidId, into: nil, keeping: nil)
        case .pullFromMac(let macId):
            guard let pair = store.pair(macId: macId), let entry = phone[pair.androidId] else { return }
            let content = try await readMac(macId)
            if isUnchanged(content, pair: pair) {
                remember(content, in: pair)
                return
            }
            try await pull(content, into: pair.androidId, baseHash: entry.hash, keeping: pair)
        case .both(let androidId):
            guard let pair = store.pair(androidId: androidId), let entry = phone[androidId] else { return }
            let content = try await readMac(pair.macId)
            if isUnchanged(content, pair: pair) {
                try await push(androidId: androidId, into: pair.macId, keeping: pair)
                return
            }
            try await conflict(pair: pair, entry: entry, mac: content)
        case .createOnPhone(let macId):
            let content = try await readMac(macId)
            try await pull(content, into: nil, baseHash: nil, keeping: nil)
        case .deleteOnMac(let macId):
            guard let pair = store.pair(macId: macId) else { return }
            try await library.delete(id: macId)
            store.removePair(androidId: pair.androidId)
            Log.info("Deleted \"\(mac[macId]?.name ?? macId)\" in Notes, as on the phone")
        case .deleteOnPhone(let androidId):
            guard let pair = store.pair(androidId: androidId) else { return }
            let answer = try await ask(MessageType.notesDelete, NotesPayload(id: androidId, baseHash: pair.androidHash), refusalIsAnswer: true)
            if answer.ok {
                store.removePair(androidId: androidId)
                Log.info("Deleted \"\(phone[androidId]?.title ?? androidId)\" on the phone, as in Notes")
            }
        case .restoreOnPhone(let macId):
            guard let pair = store.pair(macId: macId) else { return }
            let content = try await readMac(macId)
            store.removePair(androidId: pair.androidId)
            let markdown = try await pull(content, into: nil, baseHash: nil, keeping: nil)
            report(NotesConflict(
                at: now(),
                kind: NotesConflict.Kind.deletedOnPhone,
                title: content.info.name,
                macMarkdown: markdown.flatMap { forDisplay($0, assets: [:]) }
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

    // MARK: - Phone to Notes

    /// Writes the phone's note into Notes, a new one when `macId` is nil, and
    /// records the pair as it now stands. Returns the note as the phone sent it.
    @discardableResult
    private func push(androidId: String, into macId: String?, keeping pair: NotesPair?) async throws -> NoteDoc? {
        let answer = try await ask(MessageType.notesGet, NotesPayload(id: androidId), refusalIsAnswer: true)
        guard answer.ok, let doc = answer.payload.note else { return nil }
        for asset in doc.assets where !store.hasAsset(sha256: asset.sha256) {
            try await download(asset)
        }
        let byPath = assetMap(doc)
        let outgoing = NotesMarkup.html(fromMarkdown: doc.markdown)
        let work = store.freshWorkFolder()
        let files: [URL] = outgoing.files.compactMap { file in
            guard let sha = byPath[file.path], let source = store.assetURL(sha256: sha) else { return nil }
            let target = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(Self.safeFileName(file.name))
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? FileManager.default.copyItem(at: source, to: target)) == nil ? nil : target
        }
        let folder = doc.folder.isEmpty ? "Notes" : doc.folder
        let written: MacNoteInfo
        if let macId {
            written = try await library.update(id: macId, folder: folder, html: outgoing.html, files: files)
        } else {
            written = try await library.create(folder: folder, html: outgoing.html, files: files)
        }
        // Read back for what Notes made of it: the text to compare later edits to.
        let content = try await readMac(written.id)
        // Pictures come back in the body; the other files are the attachments
        // Notes keeps out of it, in their order.
        let attachedLines = outgoing.files.filter { !$0.path.hasPrefix("images/") }.map { "[\($0.name)](\($0.path))" }
        var assets = pair?.assets ?? [:]
        doc.assets.forEach { assets[$0.sha256] = $0.path }
        store.setPair(NotesPair(
            androidId: doc.id,
            macId: written.id,
            androidHash: doc.hash,
            androidFolder: doc.folder,
            macModified: content.info.modified,
            macFolder: content.info.folder,
            macMarkdown: key(content),
            assets: assets,
            macAttachments: attachedLines
        ))
        Log.info("Notes sync: \"\(written.name)\" \(macId == nil ? "added to" : "updated in") Notes")
        return doc
    }

    // MARK: - Notes to phone

    /// Writes a note of Notes onto the phone, a new one when `androidId` is
    /// nil. Returns the Markdown it was sent as, or nil when the phone left it
    /// for later: it changed there in between, or it is open being edited.
    @discardableResult
    private func pull(_ content: MacNoteContent, into androidId: String?, baseHash: String?, keeping pair: NotesPair?) async throws -> String? {
        var recorded = pair?.macAttachments
        if recorded == nil, let androidId {
            // A pair from before the lines were recorded: the phone's note has them.
            let answer = try await ask(MessageType.notesGet, NotesPayload(id: androidId), refusalIsAnswer: true)
            recorded = answer.payload.note.map { doc in
                let lines = doc.markdown.components(separatedBy: "\n")
                return lines.filter { NotesMarkup.imageLine($0) != nil } + lines.filter { NotesMarkup.fileLine($0) != nil }
            }
        }
        let resolved = resolve(content, known: pair?.assets ?? [:], recorded: recorded)
        let folder = content.info.folder
        var put = NotesPayload(id: androidId, folder: folder, markdown: resolved.markdown, baseHash: baseHash)
        for (path, sha) in resolved.uploads { try await upload(sha: sha, path: path) }
        var answer = try await ask(MessageType.notesPut, put, refusalIsAnswer: true)
        if !answer.ok, answer.reason == "missing asset" {
            // The phone lost a picture it once had; send every one this note uses.
            for (path, sha) in resolved.all where !resolved.uploads.contains(where: { $0.path == path }) {
                try await upload(sha: sha, path: path)
            }
            answer = try await ask(MessageType.notesPut, put, refusalIsAnswer: true)
        }
        guard answer.ok, let id = answer.payload.id, let hash = answer.payload.hash else {
            Log.info("Notes sync: the phone left \"\(content.info.name)\" for later (\(answer.reason ?? "no reason"))")
            return nil
        }
        put.id = id
        var assets = pair?.assets ?? [:]
        resolved.all.forEach { assets[$0.sha] = $0.path }
        store.setPair(NotesPair(
            androidId: id,
            macId: content.info.id,
            androidHash: hash,
            androidFolder: folder,
            macModified: content.info.modified,
            macFolder: folder,
            macMarkdown: key(content),
            assets: assets,
            macAttachments: resolved.attachmentLines
        ))
        Log.info("Notes sync: \"\(content.info.name)\" \(androidId == nil ? "added to" : "updated on") the phone")
        return resolved.markdown
    }

    private struct Resolved {
        var markdown: String
        /// Pictures and files the phone does not have yet, as path and checksum.
        var uploads: [(path: String, sha: String)]
        var all: [(path: String, sha: String)]
        /// What took the places of the attachments Notes keeps out of the body.
        var attachmentLines: [String]
    }

    /// The note in the phone's Markdown, every picture and file at a path on
    /// the phone: the one it already has for that checksum, or a new one.
    private func resolve(_ content: MacNoteContent, known: [String: String], recorded: [String]?) -> Resolved {
        let incoming = NotesMarkup.markdown(fromHTML: content.html, title: content.info.name)
        var markdown = incoming.markdown
        var uploads: [(String, String)] = []
        var all: [(String, String)] = []
        func place(sha: String, path: () -> String) -> String {
            if let existing = known[sha] ?? all.first(where: { $0.1 == sha })?.0 {
                if !all.contains(where: { $0.0 == existing }) { all.append((existing, sha)) }
                return existing
            }
            let fresh = path()
            uploads.append((fresh, sha))
            all.append((fresh, sha))
            return fresh
        }
        var inlineShas = Set<String>()
        for (index, image) in incoming.images.enumerated() {
            let sha = store.storeAsset(image.data)
            inlineShas.insert(sha)
            let path = place(sha: sha) { "images/\(UUID().uuidString.lowercased()).\(Self.fileExtension(forMime: image.mime))" }
            markdown = markdown.replacingOccurrences(of: "(\(NotesMarkup.imagePlaceholder(index)))", with: "(\(path))")
        }
        // The attachments Notes does not draw into the body take the places it
        // left for them, in order; any left over go at the end.
        var extra: [String] = []
        for attachment in content.attachments {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.file)) else { continue }
            let sha = store.storeAsset(data)
            guard !inlineShas.contains(sha) else { continue }
            inlineShas.insert(sha)
            let name = attachment.name ?? "attachment"
            if let ext = Self.imageExtension(data) {
                let path = place(sha: sha) { "images/\(UUID().uuidString.lowercased()).\(ext)" }
                extra.append("![](\(path))")
            } else {
                let path = place(sha: sha) { Self.phoneFilePath(name) }
                extra.append("[\(name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))](\(path))")
            }
        }
        var lines = markdown.components(separatedBy: "\n")
        let places = lines.indices.filter { lines[$0] == NotesMarkup.attachmentPlaceholder }
        // Fewer attachments came back than there are places for them: Notes
        // kept some to itself. What the phone had there stays, as long as the
        // places still match what was written.
        if extra.count < places.count, let recorded, recorded.count == places.count {
            for (place, line) in zip(places, recorded) {
                lines[place] = line
                for path in [NotesMarkup.imageLine(line)?.path, NotesMarkup.fileLine(line)?.path].compactMap({ $0 }) {
                    if let sha = known.first(where: { $0.value == path })?.key, !all.contains(where: { $0.0 == path }) {
                        all.append((path, sha))
                    }
                }
            }
            extra = []
        }
        var filled: [String] = []
        for place in places where lines[place] == NotesMarkup.attachmentPlaceholder {
            lines[place] = extra.isEmpty ? "" : extra.removeFirst()
        }
        for place in places where !lines[place].isEmpty { filled.append(lines[place]) }
        filled += extra
        markdown = (lines + extra).joined(separator: "\n")
        while markdown.hasSuffix("\n") { markdown.removeLast() }
        return Resolved(markdown: markdown, uploads: uploads, all: all, attachmentLines: filled)
    }

    /// What a note of Notes is compared by between cycles: its Markdown, the
    /// pictures in it by checksum and the places of its other attachments.
    /// Not the attachments' bytes, which Notes cannot always hand over at once.
    private func key(_ content: MacNoteContent) -> String {
        let incoming = NotesMarkup.markdown(fromHTML: content.html, title: content.info.name)
        var markdown = incoming.markdown
        for (index, image) in incoming.images.enumerated() {
            markdown = markdown.replacingOccurrences(of: NotesMarkup.imagePlaceholder(index), with: "@sha:" + notesSHA256(image.data))
        }
        return markdown
    }

    private func isUnchanged(_ content: MacNoteContent, pair: NotesPair) -> Bool {
        key(content) == pair.macMarkdown && content.info.folder == pair.macFolder
    }

    /// Notes moved the date on but nothing in the note changed.
    private func remember(_ content: MacNoteContent, in pair: NotesPair) {
        var pair = pair
        pair.macModified = content.info.modified
        store.setPair(pair)
    }

    private func readMac(_ id: String) async throws -> MacNoteContent {
        try await library.read(id: id, into: store.freshWorkFolder())
    }

    // MARK: - Conflicts

    /// Changed on both sides. As agreed: the version in Notes stays the note,
    /// and the phone's becomes a copy with a word added to its title, on both
    /// sides once the next cycle has taken the copy into Notes.
    private func conflict(pair: NotesPair, entry: NoteEntry, mac content: MacNoteContent) async throws {
        let original = try await ask(MessageType.notesGet, NotesPayload(id: pair.androidId))
        guard let doc = original.payload.note else { return }
        for asset in doc.assets where !store.hasAsset(sha256: asset.sha256) { try await download(asset) }
        let suffix = " (Android, \(Self.stamp.string(from: clock())))"
        let copy = try await ask(MessageType.notesCopy, NotesPayload(id: pair.androidId, titleSuffix: suffix))
        guard copy.payload.id != nil else { return }
        let markdown = try await pull(content, into: pair.androidId, baseHash: doc.hash, keeping: pair)
        let title = content.info.name
        report(NotesConflict(
            at: now(),
            kind: NotesConflict.Kind.edited,
            title: title,
            phoneMarkdown: forDisplay(doc.markdown, assets: assetMap(doc)),
            macMarkdown: markdown.map { forDisplay($0, assets: [:]) } ?? key(content),
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
        var known = assets
        for pair in store.pairs { pair.assets.forEach { known[$0.value] = $0.key } }
        return markdown.components(separatedBy: "\n").map { line in
            guard let image = NotesMarkup.imageLine(line), let sha = known[image.path] else { return line }
            return "![](asset:\(sha))"
        }.joined(separator: "\n")
    }

    private func assetMap(_ doc: NoteDoc) -> [String: String] {
        Dictionary(doc.assets.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Folders and the first sync

    /// Folders of the phone that Notes has not got yet. The other way round they
    /// come with their first note: the phone makes a folder for a note it is given.
    private func createFolders(_ phoneFolders: [String], existing: Set<String>) async throws {
        let missing = phoneFolders.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }
        let all = Set(try await library.folders())
        for folder in missing where !all.contains(folder) { try await library.ensureFolder(folder) }
    }

    /// The same note on both sides before they were ever synced - same folder,
    /// same title, same words - becomes a pair instead of two copies of each.
    private func pairTheSame(phone: [NoteEntry], mac: [MacNoteInfo]) async throws {
        let pairedPhone = Set(store.pairs.map(\.androidId))
        let pairedMac = Set(store.pairs.map(\.macId))
        let freeMac = mac.filter { !pairedMac.contains($0.id) }
        guard !freeMac.isEmpty else { return }
        for entry in phone where !entry.isDeleted && !pairedPhone.contains(entry.id) {
            guard let candidate = freeMac.first(where: {
                $0.folder == entry.folder && NotesMarkup.plain($0.name) == NotesMarkup.plain(entry.title) && store.pair(macId: $0.id) == nil
            }) else { continue }
            let answer = try await ask(MessageType.notesGet, NotesPayload(id: entry.id), refusalIsAnswer: true)
            guard let doc = answer.payload.note else { continue }
            let content = try await readMac(candidate.id)
            let theirs = NotesMarkup.markdown(fromHTML: content.html, title: content.info.name).markdown
            guard NotesMarkup.contentKey(theirs) == NotesMarkup.contentKey(doc.markdown) else { continue }
            var assets: [String: String] = [:]
            doc.assets.forEach { assets[$0.sha256] = $0.path }
            store.setPair(NotesPair(
                androidId: doc.id,
                macId: candidate.id,
                androidHash: doc.hash,
                androidFolder: doc.folder,
                macModified: content.info.modified,
                macFolder: content.info.folder,
                macMarkdown: key(content),
                assets: assets
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

    private func upload(sha: String, path: String) async throws {
        guard let data = store.asset(sha256: sha) else { return }
        let chunk = Self.assetChunk
        var offset = 0
        repeat {
            let end = min(offset + chunk, data.count)
            _ = try await ask(
                MessageType.notesAssetPut,
                NotesPayload(path: path, offset: Int64(offset), total: Int64(data.count), sha256: sha),
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

    // MARK: - Names and types

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

    static func mime(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        default: return "jpg"
        }
    }

    /// The type of a picture by its first bytes; nil for anything that is not one.
    static func imageExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if head.count >= 12, head[4...7] == [0x66, 0x74, 0x79, 0x70], [UInt8](head[8...11]) == Array("heic".utf8) { return "heic" }
        return nil
    }

    /// Where the phone keeps a file called `name`: a folder of its own, the
    /// name without what a Markdown link cannot hold, as `MdFile.pathFor` does.
    static func phoneFilePath(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "[\\s()\\[\\]/\\\\:*?\"<>|]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "files/\(UUID().uuidString.lowercased())/\(safe.isEmpty ? "file" : String(safe.prefix(200)))"
    }

    static func safeFileName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "[/:\\u0000-\\u001f]", with: "_", options: .regularExpression)
        return safe.isEmpty ? "file" : String(safe.prefix(200))
    }
}
