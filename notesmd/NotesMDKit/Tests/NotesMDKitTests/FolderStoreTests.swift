import XCTest
@testable import NotesMDKit

final class FolderStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesMDKitTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testANoteIsAFileNamedAfterItsTitle() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Praca", markdown: "# Pomysły: AI\ntekst")
        XCTAssertEqual(note.path, "Praca/Pomysły- AI.md")
        XCTAssertEqual(try text("Praca/Pomysły- AI.md"), "# Pomysły: AI\ntekst")
        XCTAssertEqual(note.summary.title, "Pomysły: AI")
        let second = try await store.create(folder: "Praca", markdown: "# Pomysły: AI\ninny")
        XCTAssertEqual(second.path, "Praca/Pomysły- AI 2.md")
        let snapshot = try await store.scan()
        XCTAssertEqual(snapshot.folders.map(\.name), ["Praca"])
        XCTAssertEqual(Set(snapshot.notes.map(\.id)), [note.id, second.id])
    }

    func testANewTitleRenamesTheFileAndItsAttachments() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Notes", markdown: "# Stary")
        let picture = root.appendingPathComponent("p.jpg")
        try Data([1, 2, 3]).write(to: picture)
        let link = try await store.addAsset(to: note.id, from: picture)
        XCTAssertTrue(link.hasPrefix("Stary.assets/"))
        _ = try await store.write(note.id, markdown: "# Stary\n![](\(link))")
        let renamed = try await store.write(note.id, markdown: "# Nowy tytuł\n![](\(link))")
        XCTAssertEqual(renamed.path, "Notes/Nowy tytuł.md")
        XCTAssertEqual(renamed.id, note.id)
        XCTAssertFalse(exists("Notes/Stary.md"))
        XCTAssertFalse(exists("Notes/Stary.assets"))
        let written = try text("Notes/Nowy tytuł.md")
        XCTAssertTrue(written.contains("](Nowy%20tytuł.assets/"), written)
        let image = try XCTUnwrap(Markdown.parse(written)[1].image)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.resolve(link: image.path, of: renamed))), Data([1, 2, 3]))
    }

    func testAPictureNoLongerShownIsRemoved() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Notes", markdown: "# A")
        let picture = root.appendingPathComponent("p.png")
        try Data([1]).write(to: picture)
        let link = try await store.addAsset(to: note.id, from: picture)
        try await store.writeAsset(of: note.id, inner: WireForm.strokesPath(String(FileNames.decodeLink(link).dropFirst("A.assets/".count))), data: Data("{}".utf8))
        _ = try await store.write(note.id, markdown: "# A\n![drawing](\(link))")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes/A.assets").path).count, 2)
        _ = try await store.write(note.id, markdown: "# A")
        XCTAssertFalse(exists("Notes/A.assets"))
    }

    func testOnlyOverTheVersionReadUnlessForced() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Notes", markdown: "# A\n1")
        try Data("# A\n2".utf8).write(to: root.appendingPathComponent("Notes/A.md"))
        do {
            _ = try await store.write(note.id, markdown: "# A\n3", baseSHA: note.sha)
            XCTFail("written over a change")
        } catch {
            XCTAssertEqual(error as? FolderStoreError, .changed)
        }
    }

    func testTrashRestoreAndDeleteForever() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Praca", markdown: "# Do kosza")
        try await store.trash(note.id)
        var snapshot = await store.current()
        XCTAssertTrue(snapshot.notes.isEmpty)
        XCTAssertEqual(snapshot.trash.map(\.id), [note.id])
        XCTAssertEqual(snapshot.trash.first?.folder, "Praca")
        XCTAssertTrue(exists(".notesmd/trash/\(note.id)/Do kosza.md"))
        let back = try await store.restore(note.id)
        XCTAssertEqual(back.path, "Praca/Do kosza.md")
        try await store.trash(note.id)
        try await store.deleteForever(note.id)
        snapshot = await store.current()
        XCTAssertTrue(snapshot.trash.isEmpty)
        XCTAssertFalse(exists(".notesmd/trash/\(note.id)"))
    }

    func testMoveAndDuplicateKeepAttachments() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "A", markdown: "# N")
        let file = root.appendingPathComponent("doc.pdf")
        try Data([9]).write(to: file)
        let link = try await store.addAsset(to: note.id, from: file, name: "Raport (1).pdf")
        _ = try await store.write(note.id, markdown: "# N\n[Raport (1).pdf](\(link))")
        let moved = try await store.move(note.id, to: "B")
        XCTAssertEqual(moved.path, "B/N.md")
        XCTAssertTrue(exists("B/N.assets"))
        let copy = try await store.duplicate(note.id)
        XCTAssertEqual(copy.path, "B/N (copy).md")
        let copied = try text("B/N (copy).md")
        XCTAssertTrue(copied.contains("](N%20%28copy%29.assets/"), copied)
        XCTAssertEqual(Markdown.parse(copied)[1].block.type, .file)
    }

    func testAFileRenamedInFinderKeepsItsId() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        let note = try await store.create(folder: "Notes", markdown: "# A\ntreść")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Notes/A.md"), to: root.appendingPathComponent("Notes/B.md"))
        // A file moved keeps its date; make it later than when the app last wrote its place.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.appendingPathComponent("Notes/B.md").path)
        let snapshot = try await store.scan()
        XCTAssertEqual(snapshot.notes.map(\.id), [note.id])
        XCTAssertEqual(snapshot.notes.first?.path, "Notes/B.md")
    }

    func testTwoWritersAgree() async throws {
        let mac = FolderStore(root: root, writer: "mac-test-app")
        let pad = FolderStore(root: root, writer: "ios-test")
        let note = try await mac.create(folder: "Notes", markdown: "# Wspólna")
        var snapshot = try await pad.scan()
        XCTAssertEqual(snapshot.notes.map(\.id), [note.id])
        try await pad.setPinned(note.id, true)
        snapshot = try await mac.scan()
        XCTAssertEqual(snapshot.notes.first?.pinned, true)
        _ = try await mac.write(note.id, markdown: "# Inna nazwa")
        snapshot = try await pad.scan()
        XCTAssertEqual(snapshot.notes.map(\.path), ["Notes/Inna nazwa.md"])
        XCTAssertEqual(snapshot.notes.first?.pinned, true)
    }

    func testANoteMadeOutsideGetsTheSameIdEverywhere() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# Z zewnątrz".utf8).write(to: root.appendingPathComponent("Notes/Z zewnątrz.md"))
        let mac = FolderStore(root: root, writer: "mac-test-app")
        let pad = FolderStore(root: root, writer: "ios-test")
        let a = try await mac.scan()
        let b = try await pad.scan()
        XCTAssertEqual(a.notes.map(\.id), b.notes.map(\.id))
        XCTAssertEqual(a.notes.count, 1)
    }

    func testTwoIdsOnOnePathBecomeOne() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".notesmd/devices"), withIntermediateDirectories: true)
        var one = DeviceMeta(writer: "one")
        var meta = NoteMeta()
        meta.path = "Notes/X.md"
        meta.pathTs = 10
        one.notes["b"] = meta
        var two = DeviceMeta(writer: "two")
        two.notes["a"] = meta
        try JSONEncoder().encode(one).write(to: root.appendingPathComponent(".notesmd/devices/one.json"))
        try JSONEncoder().encode(two).write(to: root.appendingPathComponent(".notesmd/devices/two.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# X".utf8).write(to: root.appendingPathComponent("Notes/X.md"))
        let store = FolderStore(root: root, writer: "three")
        let snapshot = try await store.scan()
        XCTAssertEqual(snapshot.notes.map(\.id), ["a"])
    }

    func testFolders() async throws {
        let store = FolderStore(root: root, writer: "mac-test-app")
        try await store.createFolder("Praca")
        try await store.createFolder("Dom")
        _ = try await store.create(folder: "Praca", markdown: "# W pracy")
        try await store.renameFolder("Praca", to: "Biuro")
        var snapshot = await store.current()
        XCTAssertEqual(snapshot.folders.map(\.name), ["Biuro", "Dom"])
        XCTAssertEqual(snapshot.notes.first?.path, "Biuro/W pracy.md")
        try await store.reorderFolders(["Dom", "Biuro"])
        snapshot = await store.current()
        XCTAssertEqual(snapshot.folders.map(\.name), ["Dom", "Biuro"])
        try await store.deleteFolder("Biuro")
        snapshot = await store.current()
        XCTAssertEqual(snapshot.folders.map(\.name), ["Dom"])
        XCTAssertEqual(snapshot.trash.first?.folder, "Biuro")
    }

    func testWireForm() {
        let disk = "# Pomysły AI\n![drawing](Pomysły%20AI.assets/0f8fad5b-d9cb-469f-a165-70867728950e.png)\n[Raport.pdf](Pomysły%20AI.assets/7c9e6679-7425-40de-944b-e07fc1f90ae7/Raport.pdf)"
        let wire = WireForm.toWire(disk, assetsFolder: "Pomysły AI.assets")
        XCTAssertEqual(wire.markdown, "# Pomysły AI\n![drawing](images/0f8fad5b-d9cb-469f-a165-70867728950e.png)\n[Raport.pdf](files/7c9e6679-7425-40de-944b-e07fc1f90ae7/Raport.pdf)")
        XCTAssertEqual(wire.assets.map(\.wire), ["images/0f8fad5b-d9cb-469f-a165-70867728950e.png", "files/7c9e6679-7425-40de-944b-e07fc1f90ae7/Raport.pdf"])
        XCTAssertEqual(WireForm.fromWire(wire.markdown, assetsFolder: "Pomysły AI.assets"), disk)
        XCTAssertEqual(NoteHash.hash(markdown: "a", assets: []), NoteHash.sha256("a"))
    }
}
