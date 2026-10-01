import XCTest
@testable import MacDroidSyncCore

/// The plan alone: which step each combination of changes leads to.
final class NotesSyncPlanTests: XCTestCase {

    private func pair(_ n: Int, hash: String = "h", modified: Int64 = 1) -> NotesPair {
        NotesPair(androidId: "a\(n)", macId: "m\(n)", androidHash: hash, androidFolder: "Notes",
                  macModified: modified, macFolder: "Notes", macMarkdown: "")
    }

    private func entry(_ n: Int, hash: String = "h", deleted: Bool? = nil) -> NoteEntry {
        NoteEntry(id: "a\(n)", folder: "Notes", title: "t\(n)", modified: 1, hash: hash, deleted: deleted)
    }

    private func mac(_ n: Int, modified: Int64 = 1, folder: String = "Notes") -> MacNoteInfo {
        MacNoteInfo(id: "m\(n)", name: "t\(n)", folder: folder, modified: modified)
    }

    func testEachSideChangingLeadsToItsOwnStep() {
        let result = NotesSyncPlan.plan(
            pairs: [pair(1), pair(2), pair(3), pair(4)],
            phone: [entry(1, hash: "new"), entry(2), entry(3, hash: "new"), entry(4)],
            mac: [mac(1), mac(2, modified: 9), mac(3, modified: 9), mac(4, folder: "Dom")]
        )
        XCTAssertEqual(result.steps, [
            .pushToMac(androidId: "a1"),
            .pullFromMac(macId: "m2"),
            .both(androidId: "a3"),
            .pullFromMac(macId: "m4"),
        ])
    }

    func testNotesOnOneSideOnlyAreCopiedToTheOther() {
        let result = NotesSyncPlan.plan(pairs: [], phone: [entry(1), entry(2, deleted: true)], mac: [mac(7)])
        XCTAssertEqual(result.steps, [.createOnMac(androidId: "a1"), .createOnPhone(macId: "m7")])
    }

    func testADeletionCarriesOverUnlessTheOtherSideChangedTheNote() {
        let result = NotesSyncPlan.plan(
            pairs: [pair(1), pair(2), pair(3), pair(4), pair(5)],
            phone: [entry(1, deleted: true), entry(2, deleted: true), entry(3), entry(4, hash: "new")],
            mac: [mac(1), mac(2, modified: 9)]
        )
        XCTAssertEqual(Set(result.steps.map { "\($0)" }), Set([
            NotesSyncPlan.Step.deleteOnMac(macId: "m1"),
            .restoreOnPhone(macId: "m2"),
            .deleteOnPhone(androidId: "a3"),
            .restoreOnMac(androidId: "a4"),
            .forget(androidId: "a5"),
        ].map { "\($0)" }))
    }

    func testTooManyDeletionsAtOnceWait() {
        let pairs = (1...10).map { pair($0) }
        let result = NotesSyncPlan.plan(pairs: pairs, phone: (1...10).map { entry($0) }, mac: [])
        XCTAssertEqual(result.heldDeletions, 10)
        XCTAssertTrue(result.steps.isEmpty)
        let allowed = NotesSyncPlan.plan(pairs: pairs, phone: (1...10).map { entry($0) }, mac: [], allowDeletions: true)
        XCTAssertEqual(allowed.steps.count, 10)
    }

    func testTheWirePayloadDecodesAsThePhoneWritesIt() throws {
        let json = """
        {"v":1,"seq":2,"type":"notes-manifest","ts":1,
         "notes":{"requestId":"r","folders":["Dom"],
                  "notes":[{"id":"a","folder":"Dom","title":"Lista","modified":5,"hash":"h","deleted":true,"extra":1}]}}
        """
        let message = try Message.decode(Data(json.utf8))
        XCTAssertEqual(message.notes?.notes?.first, NoteEntry(id: "a", folder: "Dom", title: "Lista", modified: 5, hash: "h", deleted: true))
        let payload = NotesPayload(requestId: "x", id: "a", markdown: "# A", baseHash: "b", offset: 3, total: 9)
        XCTAssertEqual(try Message.decode(try Message(type: MessageType.notesPut, notes: payload).encoded()).notes, payload)
    }
}

// MARK: - The whole cycle, against a phone and a Notes in memory

/// Notes in memory. Like the real one it rewrites nothing; what matters here
/// is the sync's own bookkeeping, the conversion has tests of its own.
private final class FakeNotes: NotesLibrary {
    struct Note {
        var info: MacNoteInfo
        var html: String
    }

    var notes: [String: Note] = [:]
    var deleted: [String] = []
    private var counter = 0
    private var tick: Int64 = 100

    func add(name: String, folder: String = "Notes", html: String) -> String {
        counter += 1
        tick += 1
        let id = "mac-\(counter)"
        notes[id] = Note(info: MacNoteInfo(id: id, name: name, folder: folder, modified: tick), html: html)
        return id
    }

    func edit(_ id: String, html: String) {
        tick += 1
        notes[id]?.html = html
        notes[id]?.info.modified = tick
    }

    func list() async throws -> [MacNoteInfo] { notes.values.map(\.info).sorted { $0.id < $1.id } }
    func folders() async throws -> [String] { Array(Set(notes.values.map(\.info.folder))) }

    func read(id: String, into folder: URL) async throws -> MacNoteContent {
        guard let note = notes[id] else { throw NotesLibraryError.failed("no note \(id)") }
        return MacNoteContent(info: note.info, html: note.html, attachments: [])
    }

    /// As Notes does with attached files: a picture shows at the end of the
    /// body, anything else leaves an empty line there and cannot be read back
    /// when `hidesFiles` is set.
    private func stored(_ html: String, _ files: [URL]) -> String {
        html + files.map { file in
            if ["jpg", "png"].contains(file.pathExtension), let data = try? Data(contentsOf: file) {
                return "<div><img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\"/></div>"
            }
            return "<div><br><br></div>"
        }.joined()
    }

    func create(folder: String, html: String, files: [URL]) async throws -> MacNoteInfo {
        let html = stored(html, files)
        let name = NotesMarkup.markdown(fromHTML: html, title: "").markdown.components(separatedBy: "\n").first.map {
            $0.hasPrefix("# ") ? String($0.dropFirst(2)) : $0
        } ?? ""
        let id = add(name: name, folder: folder, html: html)
        return notes[id]!.info
    }

    func update(id: String, folder: String, html: String, files: [URL]) async throws -> MacNoteInfo {
        writes += 1
        edit(id, html: stored(html, files))
        notes[id]?.info.folder = folder
        return notes[id]!.info
    }

    var writes = 0

    func move(id: String, folder: String) async throws -> MacNoteInfo {
        tick += 1
        notes[id]?.info.folder = folder
        notes[id]?.info.modified = tick
        return notes[id]!.info
    }

    func delete(id: String) async throws {
        notes[id] = nil
        deleted.append(id)
    }

    func ensureFolder(_ name: String) async throws {}
}

/// The phone's side, as NotesHost on Android does it.
@MainActor
private final class FakePhone {
    struct Note {
        var folder: String
        var markdown: String
        var deleted = false
    }

    var notes: [String: Note] = [:]
    var assets: [String: Data] = [:]
    var writes = 0
    var writtenFolders = 0
    var editing: Set<String> = []
    weak var coordinator: NotesCoordinator?
    private var counter = 0

    func hash(_ markdown: String) -> String { notesSHA256(Data(markdown.utf8)) }

    @discardableResult
    func add(_ markdown: String, folder: String = "Notes") -> String {
        counter += 1
        let id = "phone-\(counter)"
        notes[id] = Note(folder: folder, markdown: markdown)
        return id
    }

    func transport(_ type: String, _ request: NotesPayload, _ data: Data?) -> Bool {
        var reply = NotesPayload(requestId: request.requestId, id: request.id)
        var ok = true
        var reason: String?
        switch type {
        case MessageType.notesManifest:
            reply.folders = Array(Set(notes.values.map(\.folder)))
            reply.notes = notes.map { id, note in
                NoteEntry(id: id, folder: note.folder, title: NotesCoordinator.title(of: note.markdown), modified: 1,
                          hash: note.deleted ? "" : hash(note.markdown), deleted: note.deleted ? true : nil)
            }
        case MessageType.notesGet:
            if let id = request.id, let note = notes[id], !note.deleted {
                let used = note.markdown.components(separatedBy: "\n").compactMap { NotesMarkup.imageLine($0)?.path ?? NotesMarkup.fileLine($0)?.path }
                let list = used.compactMap { path in assets[path].map { NoteAsset(path: path, size: Int64($0.count), sha256: notesSHA256($0)) } }
                reply.note = NoteDoc(id: id, folder: note.folder, markdown: note.markdown, hash: hash(note.markdown), assets: list)
            } else {
                ok = false
                reason = "missing"
            }
        case MessageType.notesPut:
            if let id = request.id, editing.contains(id) {
                ok = false
                reason = "editing"
            } else if let id = request.id, let base = request.baseHash, let note = notes[id], hash(note.markdown) != base {
                ok = false
                reason = "changed"
            } else if let id = request.id, request.markdown == nil {
                writtenFolders += 1
                notes[id]?.folder = request.folder ?? "Notes"
                reply.hash = notes[id].map { hash($0.markdown) }
            } else {
                writes += 1
                let id = request.id ?? add("", folder: request.folder ?? "Notes")
                notes[id] = Note(folder: request.folder ?? "Notes", markdown: request.markdown ?? "")
                reply.id = id
                reply.hash = hash(request.markdown ?? "")
            }
        case MessageType.notesAssetGet:
            let data = assets[request.path ?? ""] ?? Data()
            reply.offset = request.offset
            reply.total = Int64(data.count)
            let answer = NotesReply(type: type, payload: reply, ok: true, reason: nil, data: data)
            Task { @MainActor in self.coordinator?.handle(answer) }
            return true
        case MessageType.notesDelete:
            if let id = request.id { notes[id]?.deleted = true }
        case MessageType.notesCopy:
            if let id = request.id, let note = notes[id] {
                var lines = note.markdown.components(separatedBy: "\n")
                lines[0] += request.titleSuffix ?? ""
                reply.id = add(lines.joined(separator: "\n"), folder: note.folder)
            }
        default:
            ok = false
        }
        let answer = NotesReply(type: type, payload: reply, ok: ok, reason: reason, data: nil)
        Task { @MainActor in self.coordinator?.handle(answer) }
        return true
    }
}

@MainActor
final class NotesCoordinatorTests: XCTestCase {

    private var directory: URL!
    private var phone: FakePhone!
    private var mac: FakeNotes!
    private var coordinator: NotesCoordinator!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-sync-\(UUID().uuidString)")
        phone = FakePhone()
        mac = FakeNotes()
        let phone = phone!
        coordinator = NotesCoordinator(
            store: NotesSyncStore(directory: directory),
            library: mac,
            timeout: 5,
            pollInterval: 3600,
            transport: { phone.transport($0, $1, $2) }
        )
        phone.coordinator = coordinator
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sync() async {
        coordinator.setEnabled(true)
        if !coordinator.isConnected { coordinator.connected() } else { coordinator.requestSync() }
        for _ in 0..<500 where coordinator.isRunning { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.lastError)
    }

    private func macNote(named name: String) -> FakeNotes.Note? {
        mac.notes.values.first { $0.info.name == name }
    }

    func testTheFirstSyncCopiesBothWaysAndKeepsWhatIsAlreadyTheSame() async {
        phone.add("# Z telefonu\ntekst", folder: "Dom")
        phone.add("# Wspólna\nto samo")
        _ = mac.add(name: "Z Maca", html: "<div><h1>Z Maca</h1></div><div>z Notatek</div>")
        _ = mac.add(name: "Wspólna", html: "<div><h1>Wspólna</h1></div><div>to samo</div>")
        await sync()
        XCTAssertEqual(macNote(named: "Z telefonu")?.info.folder, "Dom")
        XCTAssertTrue(phone.notes.values.contains { $0.markdown == "# Z Maca\nz Notatek" })
        XCTAssertEqual(mac.notes.count, 3)
        XCTAssertEqual(phone.notes.count, 3)
        XCTAssertEqual(coordinator.store.pairs.count, 3)
    }

    func testAnEditOnEitherSideReachesTheOther() async {
        let id = phone.add("# Lista\nmleko")
        await sync()
        phone.notes[id]?.markdown = "# Lista\nmleko\nchleb"
        await sync()
        XCTAssertTrue(macNote(named: "Lista")!.html.contains("chleb"))

        let macId = coordinator.store.pair(androidId: id)!.macId
        mac.edit(macId, html: "<div><h1>Lista</h1></div><div>tylko woda</div>")
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\ntylko woda")
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testANewerDateInNotesWithTheSameTextIsNoEdit() async {
        let id = phone.add("# Lista\nmleko")
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        mac.edit(macId, html: mac.notes[macId]!.html)
        phone.notes[id]?.markdown = "# Lista\nmleko i miód"
        await sync()
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
        XCTAssertTrue(mac.notes[macId]!.html.contains("miód"))
    }

    func testAnEditOnBothSidesKeepsTheMacsVersionAndCopiesThePhones() async {
        let id = phone.add("# Plan\nwersja bazowa")
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        phone.notes[id]?.markdown = "# Plan\nwersja z telefonu"
        mac.edit(macId, html: "<div><h1>Plan</h1></div><div>wersja z Maca</div>")
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Plan\nwersja z Maca")
        let copy = phone.notes.values.first { $0.markdown.hasPrefix("# Plan (Android, ") }
        XCTAssertEqual(copy?.markdown.components(separatedBy: "\n").last, "wersja z telefonu")
        XCTAssertNotNil(mac.notes.values.first { $0.info.name.hasPrefix("Plan (Android, ") })
        let conflict = coordinator.store.conflicts.first
        XCTAssertEqual(conflict?.kind, NotesConflict.Kind.edited)
        XCTAssertEqual(conflict?.phoneMarkdown, "# Plan\nwersja z telefonu")
        XCTAssertEqual(conflict?.macMarkdown, "# Plan\nwersja z Maca")
    }

    func testDeletionsCarryOverBothWays() async {
        let first = phone.add("# Pierwsza")
        let second = phone.add("# Druga")
        await sync()
        phone.notes[first]?.deleted = true
        let secondMac = coordinator.store.pair(androidId: second)!.macId
        try? await mac.delete(id: secondMac)
        await sync()
        XCTAssertNil(macNote(named: "Pierwsza"))
        XCTAssertEqual(phone.notes[second]?.deleted, true)
        XCTAssertTrue(coordinator.store.pairs.isEmpty)
    }

    func testANoteBeingEditedOnThePhoneWaitsForTheNextCycle() async {
        let id = phone.add("# Lista\nmleko")
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        mac.edit(macId, html: "<div><h1>Lista</h1></div><div>z Maca</div>")
        phone.editing = [id]
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\nmleko")
        phone.editing = []
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\nz Maca")
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testPicturesGoToNotesAsFilesAndKeepTheirPathOnThePhone() async {
        let path = "images/00000000-0000-0000-0000-000000000009.jpg"
        phone.assets[path] = Data([0xFF, 0xD8, 0xFF, 0x01])
        let id = phone.add("# Morze\n![](\(path))\ntekst")
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        XCTAssertTrue(mac.notes[macId]!.html.contains("<img"))
        mac.edit(macId, html: mac.notes[macId]!.html.replacingOccurrences(of: "tekst", with: "tekst z Maca"))
        await sync()
        // Notes holds attached pictures at the end, and so does the phone after an edit there.
        XCTAssertEqual(phone.notes[id]?.markdown, "# Morze\ntekst z Maca\n![](\(path))")
    }

    func testAFileNotesWillNotHandBackStaysOnThePhone() async {
        let path = "files/00000000-0000-0000-0000-000000000009/nagranie.m4a"
        let id = phone.add("# Dyktafon\n[nagranie.m4a](\(path))\ntekst")
        phone.assets[path] = Data([1, 2, 3])
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        XCTAssertTrue(mac.notes[macId]!.html.contains("<br><br>"))
        mac.edit(macId, html: mac.notes[macId]!.html.replacingOccurrences(of: "tekst", with: "tekst z Maca"))
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Dyktafon\ntekst z Maca\n[nagranie.m4a](\(path))")
    }

    func testAMoveOnEitherSideMovesTheNoteAndWritesNothing() async {
        let id = phone.add("* lista\n# Tytuł")
        phone.notes[id]?.markdown = "# Plan\n* punkt z gwiazdką\n![](images/00000000-0000-0000-0000-00000000000a.jpg)"
        phone.assets["images/00000000-0000-0000-0000-00000000000a.jpg"] = Data([0xFF, 0xD8, 0xFF])
        await sync()
        let macId = coordinator.store.pair(androidId: id)!.macId
        let macWrites = mac.writes
        let phoneWrites = phone.writes

        phone.notes[id]?.folder = "Praca"
        await sync()
        XCTAssertEqual(mac.notes[macId]?.info.folder, "Praca")
        XCTAssertEqual(mac.writes, macWrites)

        _ = try? await mac.move(id: macId, folder: "Dom")
        await sync()
        XCTAssertEqual(phone.notes[id]?.folder, "Dom")
        XCTAssertEqual(phone.notes[id]?.markdown, "# Plan\n* punkt z gwiazdką\n![](images/00000000-0000-0000-0000-00000000000a.jpg)")
        XCTAssertEqual(phone.writes, phoneWrites)
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testTooManyDeletionsWaitForTheOperator() async {
        let ids = (1...8).map { phone.add("# Notatka \($0)") }
        await sync()
        ids.forEach { phone.notes[$0]?.deleted = true }
        await sync()
        XCTAssertEqual(mac.notes.count, 8)
        XCTAssertEqual(coordinator.store.conflicts.first?.kind, NotesConflict.Kind.deletions)
        coordinator.allowHeldDeletions()
        for _ in 0..<500 where coordinator.isRunning { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(mac.notes.count, 0)
    }
}
