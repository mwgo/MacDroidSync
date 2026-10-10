import XCTest
import NotesMDKit
@testable import MacDroidSyncCore

/// The plan alone: which step each combination of changes leads to.
final class NotesSyncPlanTests: XCTestCase {

    private func pair(_ n: Int, hash: String = "h") -> NotesPair {
        NotesPair(androidId: "a\(n)", macId: "m\(n)", androidHash: hash, androidFolder: "Notes", macHash: "1", macFolder: "Notes")
    }

    private func entry(_ n: Int, hash: String = "h", deleted: Bool? = nil) -> NoteEntry {
        NoteEntry(id: "a\(n)", folder: "Notes", title: "t\(n)", modified: 1, hash: hash, deleted: deleted)
    }

    private func mac(_ n: Int, modified: Int64 = 1, folder: String = "Notes") -> MacNoteInfo {
        MacNoteInfo(id: "m\(n)", name: "t\(n)", folder: folder, modified: modified, hash: "\(modified)")
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

// MARK: - The whole cycle, against a phone in memory and a folder of notes

/// The phone's side, as NotesHost on Android does it.
@MainActor
private final class FakePhone {
    struct Note {
        var folder: String
        var markdown: String
        var deleted = false
    }

    var notes: [String: Note] = [:] {
        didSet { folders.formUnion(notes.values.map(\.folder)) }
    }
    /// As the phone keeps them: a folder stays when its notes go.
    var folders: Set<String> = []
    /// What the last notes-synced said Notes holds as it is.
    var synced: [String: String] = [:]
    var assets: [String: Data] = [:]
    private var partial: [String: Data] = [:]
    var writes = 0
    var writtenFolders = 0
    var editing: Set<String> = []
    weak var coordinator: NotesCoordinator?
    private var counter = 0

    /// As the phone does with `sidecars`: every picture and file, a drawing's strokes after its picture.
    func assetList(_ markdown: String) -> [NoteAsset] {
        Markdown.assetPaths(markdown).flatMap { path -> [NoteAsset] in
            guard let data = assets[path] else { return [] }
            var list = [NoteAsset(path: path, size: Int64(data.count), sha256: notesSHA256(data))]
            let strokes = WireForm.strokesPath(path)
            if path.hasPrefix("images/"), let more = assets[strokes] {
                list.append(NoteAsset(path: strokes, size: Int64(more.count), sha256: notesSHA256(more)))
            }
            return list
        }
    }

    func hash(_ markdown: String) -> String {
        NoteHash.hash(markdown: markdown, assets: assetList(markdown).map { ($0.path, $0.sha256) })
    }

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
            reply.folders = Array(folders)
            reply.notes = notes.map { id, note in
                NoteEntry(id: id, folder: note.folder, title: NotesCoordinator.title(of: note.markdown), modified: 1,
                          hash: note.deleted ? "" : hash(note.markdown), deleted: note.deleted ? true : nil)
            }
        case MessageType.notesGet:
            if let id = request.id, let note = notes[id], !note.deleted {
                let list = assetList(note.markdown)
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
            } else if let markdown = request.markdown, Markdown.assetPaths(markdown).contains(where: { assets[$0] == nil }) {
                ok = false
                reason = "missing asset"
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
        case MessageType.notesAssetPut:
            if let path = request.path, let data {
                let start = Int(request.offset ?? 0)
                var current = start == 0 ? Data() : (partial[path] ?? Data())
                current.append(data)
                partial[path] = current
                if Int64(current.count) >= request.total ?? 0 { assets[path] = current }
                reply.offset = Int64(current.count)
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
        case MessageType.notesFolderDelete:
            let folder = request.folder ?? ""
            if notes.values.contains(where: { $0.folder == folder && !$0.deleted }) {
                ok = false
                reason = "not empty"
            } else {
                folders.remove(folder)
            }
        case MessageType.notesSynced:
            synced = Dictionary((request.notes ?? []).map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a })
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
    private var root: URL!
    private var phone: FakePhone!
    private var library: FolderNotesLibrary!
    private var coordinator: NotesCoordinator!
    private let clock = TestClock()

    final class TestClock: @unchecked Sendable {
        var now = Date()
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-sync-\(UUID().uuidString)")
        root = directory.appendingPathComponent("iCloud", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        phone = FakePhone()
        let clock = clock
        library = FolderNotesLibrary(root: root, writer: "mac-test-sync", clock: { clock.now })
        let phone = phone!
        coordinator = NotesCoordinator(
            store: NotesSyncStore(directory: directory.appendingPathComponent("state")),
            library: library,
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
        for _ in 0..<1000 where coordinator.isRunning { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.lastError)
    }

    private func file(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheFirstSyncCopiesBothWaysAndKeepsWhatIsAlreadyTheSame() async throws {
        phone.add("# Z telefonu\ntekst", folder: "Dom")
        phone.add("# Wspólna\nto samo")
        try write("Notes/Z Maca.md", "# Z Maca\nz folderu")
        try write("Notes/Wspólna.md", "# Wspólna\nto samo")
        await sync()
        XCTAssertEqual(file("Dom/Z telefonu.md"), "# Z telefonu\ntekst")
        XCTAssertTrue(phone.notes.values.contains { $0.markdown == "# Z Maca\nz folderu" })
        XCTAssertEqual(phone.notes.count, 3)
        XCTAssertEqual(coordinator.store.pairs.count, 3)
        XCTAssertNil(file("Notes/Wspólna 2.md"))
    }

    func testAnEditOnEitherSideReachesTheOther() async throws {
        let id = phone.add("# Lista\nmleko")
        await sync()
        phone.notes[id]?.markdown = "# Lista\nmleko\nchleb"
        await sync()
        XCTAssertEqual(file("Notes/Lista.md"), "# Lista\nmleko\nchleb")

        try write("Notes/Lista.md", "# Lista\ntylko woda")
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\ntylko woda")
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testANewTitleOnThePhoneRenamesTheFile() async throws {
        let id = phone.add("# Stary")
        await sync()
        phone.notes[id]?.markdown = "# Nowy\ntekst"
        await sync()
        XCTAssertNil(file("Notes/Stary.md"))
        XCTAssertEqual(file("Notes/Nowy.md"), "# Nowy\ntekst")
        XCTAssertEqual(coordinator.store.pairs.count, 1)
    }

    func testAnEditOnBothSidesKeepsTheMacsVersionAndCopiesThePhones() async throws {
        let id = phone.add("# Plan\nwersja bazowa")
        await sync()
        phone.notes[id]?.markdown = "# Plan\nwersja z telefonu"
        try write("Notes/Plan.md", "# Plan\nwersja z Maca")
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Plan\nwersja z Maca")
        let copy = phone.notes.values.first { $0.markdown.hasPrefix("# Plan (Android, ") }
        XCTAssertEqual(copy?.markdown.components(separatedBy: "\n").last, "wersja z telefonu")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path)
        XCTAssertTrue(names.contains { $0.hasPrefix("Plan (Android, ") }, "\(names)")
        let conflict = coordinator.store.conflicts.first
        XCTAssertEqual(conflict?.kind, NotesConflict.Kind.edited)
        XCTAssertEqual(conflict?.phoneMarkdown, "# Plan\nwersja z telefonu")
        XCTAssertEqual(conflict?.macMarkdown, "# Plan\nwersja z Maca")
    }

    func testDeletionsCarryOverBothWays() async throws {
        let first = phone.add("# Pierwsza")
        let second = phone.add("# Druga")
        await sync()
        phone.notes[first]?.deleted = true
        try FileManager.default.removeItem(at: root.appendingPathComponent("Notes/Druga.md"))
        await sync()
        XCTAssertEqual(phone.notes[second]?.deleted, false, "a file gone a moment ago may be a rename iCloud has not finished")
        // Gone for good once iCloud would have settled; a look at the folder alone starts the cycle that says so.
        clock.now = clock.now.addingTimeInterval(300)
        coordinator.folderChanged()
        for _ in 0..<200 where phone.notes[second]?.deleted != true { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(file("Notes/Pierwsza.md"))
        XCTAssertEqual(phone.notes[second]?.deleted, true)
        let snapshot = await library.store.current()
        XCTAssertEqual(snapshot.trash.map(\.title), ["Pierwsza"])
    }

    func testANoteBeingEditedOnThePhoneWaitsForTheNextCycle() async throws {
        let id = phone.add("# Lista\nmleko")
        await sync()
        try write("Notes/Lista.md", "# Lista\nz Maca")
        phone.editing = [id]
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\nmleko")
        phone.editing = []
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Lista\nz Maca")
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testPicturesFilesAndStrokesGoBothWays() async throws {
        let picture = "images/00000000-0000-0000-0000-000000000009.png"
        let strokes = "images/00000000-0000-0000-0000-000000000009.json"
        let file = "files/00000000-0000-0000-0000-00000000000a/nagranie.m4a"
        phone.assets[picture] = Data([0x89, 0x50, 0x4E, 0x47])
        phone.assets[strokes] = Data("{\"strokes\":[]}".utf8)
        phone.assets[file] = Data([1, 2, 3])
        let id = phone.add("# Morze\n![drawing](\(picture))\n[nagranie.m4a](\(file))\ntekst")
        await sync()
        let written = try XCTUnwrap(self.file("Notes/Morze.md"))
        XCTAssertEqual(written, "# Morze\n![drawing](Morze.assets/00000000-0000-0000-0000-000000000009.png)\n[nagranie.m4a](Morze.assets/00000000-0000-0000-0000-00000000000a/nagranie.m4a)\ntekst")
        XCTAssertEqual(self.file("Notes/Morze.assets/00000000-0000-0000-0000-000000000009.json"), "{\"strokes\":[]}")

        try write("Notes/Morze.assets/00000000-0000-0000-0000-000000000009.json", "{\"strokes\":[1]}")
        try write("Notes/Morze.md", written.replacingOccurrences(of: "tekst", with: "tekst z Maca"))
        await sync()
        XCTAssertEqual(phone.notes[id]?.markdown, "# Morze\n![drawing](\(picture))\n[nagranie.m4a](\(file))\ntekst z Maca")
        XCTAssertEqual(phone.assets[strokes], Data("{\"strokes\":[1]}".utf8))
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testAMoveOnEitherSideMovesTheNoteAndWritesNothing() async throws {
        let id = phone.add("# Plan\npunkt")
        await sync()
        let phoneWrites = phone.writes
        phone.notes[id]?.folder = "Praca"
        await sync()
        XCTAssertEqual(file("Praca/Plan.md"), "# Plan\npunkt")
        XCTAssertNil(file("Notes/Plan.md"))

        let pair = try XCTUnwrap(coordinator.store.pair(androidId: id))
        _ = try await library.move(id: pair.macId, folder: "Dom")
        await sync()
        XCTAssertEqual(phone.notes[id]?.folder, "Dom")
        XCTAssertEqual(phone.writes, phoneWrites)
        XCTAssertTrue(coordinator.store.conflicts.isEmpty)
    }

    func testTooManyDeletionsWaitForTheOperator() async throws {
        let ids = (1...8).map { phone.add("# Notatka \($0)") }
        await sync()
        ids.forEach { phone.notes[$0]?.deleted = true }
        await sync()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path).count, 8)
        XCTAssertEqual(coordinator.store.conflicts.first?.kind, NotesConflict.Kind.deletions)
        coordinator.allowHeldDeletions()
        for _ in 0..<1000 where coordinator.isRunning { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path).count, 0)
    }

    func testFoldersFollowBothWays() async throws {
        phone.folders.insert("Pusty")
        phone.add("# Notatka\ntekst")
        await sync()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pusty").path, isDirectory: &isDirectory))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Pusty"))
        await sync()
        XCTAssertFalse(phone.folders.contains("Pusty"))
        phone.folders.insert("Nowy")
        await sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowy").path))
        phone.folders.remove("Nowy")
        await sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowy").path))
    }

    func testThePhoneLearnsWhichNotesTheMacHoldsAsTheyAre() async {
        let a = phone.add("# A\nraz")
        let b = phone.add("# B\ndwa")
        await sync()
        XCTAssertEqual(Set(phone.synced.keys), [a, b])
        XCTAssertEqual(phone.synced[a], phone.hash("# A\nraz"))
    }
}
