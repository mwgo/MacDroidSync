import XCTest
@testable import MacDroidSyncCore

/// A phone that keeps its side of a pair in a temporary folder and answers as
/// PROTOCOL.md section 10 says the phone does.
@MainActor
private final class FakePhone {
    let root: URL
    var editing: Set<String> = []
    weak var coordinator: FolderSyncCoordinator?
    private var parts: [String: Data] = [:]

    init(root: URL) {
        self.root = root
    }

    func send(_ type: String, _ payload: FolderPayload, _ data: Data?) -> Bool {
        let reply = answer(type, payload, data)
        DispatchQueue.main.async { [weak self] in self?.coordinator?.handle(reply) }
        return true
    }

    private func refuse(_ type: String, _ payload: FolderPayload, _ reason: String) -> FolderReply {
        FolderReply(type: type, payload: FolderPayload(requestId: payload.requestId), ok: false, reason: reason, data: nil)
    }

    private func answer(_ type: String, _ payload: FolderPayload, _ data: Data?) -> FolderReply {
        let fm = FileManager.default
        var out = FolderPayload(requestId: payload.requestId)
        switch type {
        case MessageType.folderManifest:
            var entries: [FolderEntry] = []
            let walker = fm.enumerator(atPath: root.path)!
            while let path = walker.nextObject() as? String {
                let url = root.appendingPathComponent(path)
                if FolderRules.isExcluded(name: url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    entries.append(FolderEntry(p: path, d: true))
                } else {
                    let data = try! Data(contentsOf: url)
                    entries.append(FolderEntry(p: path, s: Int64(data.count), m: 0, h: folderSHA256(data)))
                }
            }
            out.entries = entries
        case MessageType.folderGet:
            let data = try! Data(contentsOf: url(payload.path!))
            let offset = Int(payload.offset ?? 0)
            let end = min(offset + FolderRules.chunk, data.count)
            out.offset = Int64(offset)
            out.total = Int64(data.count)
            return FolderReply(type: type, payload: out, ok: true, reason: nil, data: data.subdata(in: offset..<end))
        case MessageType.folderPut:
            let path = payload.path!
            let target = url(path)
            if payload.dir == true {
                try! fm.createDirectory(at: target, withIntermediateDirectories: true)
                break
            }
            if editing.contains(path) { return refuse(type, payload, "editing") }
            if payload.offset == 0 {
                if let reason = check(target, payload.baseHash) { return refuse(type, payload, reason) }
                parts[path] = Data()
            }
            parts[path]?.append(data ?? Data())
            if Int64(parts[path]!.count) >= payload.total! {
                let whole = parts.removeValue(forKey: path)!
                guard folderSHA256(whole) == payload.sha256 else { return refuse(type, payload, "checksum") }
                try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! whole.write(to: target)
            }
        case MessageType.folderMove:
            let source = url(payload.path!)
            let target = url(payload.to!)
            if editing.contains(payload.path!) { return refuse(type, payload, "editing") }
            if let reason = check(source, payload.baseHash) { return refuse(type, payload, reason) }
            if fm.fileExists(atPath: target.path) { return refuse(type, payload, "exists") }
            try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! fm.moveItem(at: source, to: target)
        case MessageType.folderDelete:
            let target = url(payload.path!)
            guard fm.fileExists(atPath: target.path) else { return refuse(type, payload, "missing") }
            if payload.dir == true {
                if !(try! fm.contentsOfDirectory(atPath: target.path)).isEmpty { return refuse(type, payload, "not empty") }
            } else if let reason = check(target, payload.baseHash) {
                return refuse(type, payload, reason)
            }
            try! fm.removeItem(at: target)
        default:
            return refuse(type, payload, "unknown")
        }
        return FolderReply(type: type, payload: out, ok: true, reason: nil, data: nil)
    }

    private func check(_ url: URL, _ baseHash: String?) -> String? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch (exists, baseHash) {
        case (false, nil): return nil
        case (false, .some): return "missing"
        case (true, nil): return "changed"
        case (true, let hash?): return folderSHA256(try! Data(contentsOf: url)) == hash ? nil : "changed"
        }
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

@MainActor
final class FolderSyncCoordinatorTests: XCTestCase {

    private var temp: URL!
    private var mac: URL!
    private var phone: FakePhone!
    private var coordinator: FolderSyncCoordinator!
    private var pair: FolderPair!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSyncTests-\(UUID().uuidString)")
        mac = temp.appendingPathComponent("mac", isDirectory: true)
        let phoneRoot = temp.appendingPathComponent("phone", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: phoneRoot, withIntermediateDirectories: true)
        phone = FakePhone(root: phoneRoot)
        let phone = phone!
        coordinator = FolderSyncCoordinator(
            directory: temp.appendingPathComponent("state", isDirectory: true),
            pollInterval: 3600,
            settleWrites: 0,
            useTrash: false
        ) { type, payload, data in
            MainActor.assumeIsolated { phone.send(type, payload, data) }
        }
        phone.coordinator = coordinator
        pair = FolderPair(id: "p1", name: "Test", phonePath: "Documents/Test", macPath: mac.path)
        coordinator.setPairs([pair])
        coordinator.connected()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ text: String, _ path: String, on root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, on root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ path: String, on root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func sync() async throws {
        coordinator.requestSync()
        for _ in 0..<500 {
            if coordinator.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isIdle)
        XCTAssertNil(coordinator.status(of: pair).lastError)
    }

    func testFirstSyncCopiesBothWays() async throws {
        try write("phone", "Notes/A.md", on: phone.root)
        try write("mac", "Work/B.md", on: mac)
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try await sync()
        XCTAssertEqual(read("Notes/A.md", on: mac), "phone")
        XCTAssertEqual(read("Work/B.md", on: phone.root), "mac")
        XCTAssertTrue(exists("Empty", on: phone.root))
    }

    func testChangesFollowEitherWay() async throws {
        try write("one", "a.md", on: phone.root)
        try await sync()
        try write("two", "a.md", on: phone.root)
        try await sync()
        XCTAssertEqual(read("a.md", on: mac), "two")
        try write("three", "a.md", on: mac)
        try await sync()
        XCTAssertEqual(read("a.md", on: phone.root), "three")
    }

    func testLargeFileInPieces() async throws {
        let big = String(repeating: "x", count: FolderRules.chunk * 2 + 17)
        try write(big, "big.bin", on: mac)
        try await sync()
        XCTAssertEqual(read("big.bin", on: phone.root), big)
        try write(big + "y", "big.bin", on: phone.root)
        try await sync()
        XCTAssertEqual(read("big.bin", on: mac), big + "y")
    }

    func testConflictKeepsBoth() async throws {
        try write("base", "Plan.md", on: mac)
        try await sync()
        try write("phone edit", "Plan.md", on: phone.root)
        try write("mac edit", "Plan.md", on: mac)
        try await sync()
        try await sync()
        XCTAssertEqual(read("Plan.md", on: mac), "mac edit")
        XCTAssertEqual(read("Plan.md", on: phone.root), "mac edit")
        let copies = try FileManager.default.contentsOfDirectory(atPath: mac.path).filter { $0.hasPrefix("Plan (Android, ") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(read(copies[0], on: mac), "phone edit")
        XCTAssertEqual(read(copies[0], on: phone.root), "phone edit")
        XCTAssertEqual(coordinator.store(for: pair).state.conflicts.first?.kind, FolderConflict.Kind.edited)
    }

    func testDeletionsFollow() async throws {
        for name in ["a", "b", "c", "d", "e", "f"] { try write(name, "\(name).md", on: mac) }
        try await sync()
        try FileManager.default.removeItem(at: mac.appendingPathComponent("a.md"))
        try FileManager.default.removeItem(at: phone.url("b.md"))
        try await sync()
        XCTAssertFalse(exists("a.md", on: phone.root))
        XCTAssertFalse(exists("b.md", on: mac))
        XCTAssertTrue(exists("c.md", on: mac))
    }

    func testTooManyDeletionsWaitForPermission() async throws {
        for index in 0..<8 { try write("\(index)", "f\(index).md", on: mac) }
        try await sync()
        for index in 0..<7 { try FileManager.default.removeItem(at: phone.url("f\(index).md")) }
        try await sync()
        XCTAssertTrue(exists("f0.md", on: mac))
        XCTAssertEqual(coordinator.store(for: pair).state.conflicts.first?.kind, FolderConflict.Kind.deletions)
        coordinator.allowHeldDeletions(pair)
        try await sync()
        XCTAssertFalse(exists("f0.md", on: mac))
        XCTAssertTrue(exists("f7.md", on: mac))
    }

    func testRenameMovesWithoutSending() async throws {
        try write("text", "Notes/Old.md", on: mac)
        try write("img", "Notes/Old.assets/x.jpg", on: mac)
        try await sync()
        let fm = FileManager.default
        try fm.moveItem(at: phone.url("Notes/Old.md"), to: phone.url("Notes/New.md"))
        try fm.moveItem(at: phone.url("Notes/Old.assets"), to: phone.url("Notes/New.assets"))
        try await sync()
        XCTAssertEqual(read("Notes/New.md", on: mac), "text")
        XCTAssertEqual(read("Notes/New.assets/x.jpg", on: mac), "img")
        XCTAssertFalse(exists("Notes/Old.md", on: mac))
        XCTAssertFalse(exists("Notes/Old.assets", on: mac))
    }

    func testEditingOnThePhoneWaits() async throws {
        try write("one", "a.md", on: mac)
        try await sync()
        phone.editing = ["a.md"]
        try write("two", "a.md", on: mac)
        coordinator.requestSync()
        for _ in 0..<100 where !coordinator.isIdle { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(read("a.md", on: phone.root), "one")
        phone.editing = []
        try await sync()
        XCTAssertEqual(read("a.md", on: phone.root), "two")
    }

    func testEmptyPhoneFolderDeletesNothing() async throws {
        try write("x", "a.md", on: mac)
        try await sync()
        try FileManager.default.removeItem(at: phone.url("a.md"))
        coordinator.requestSync()
        for _ in 0..<100 where !coordinator.isIdle { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(exists("a.md", on: mac))
        XCTAssertEqual(coordinator.store(for: pair).state.conflicts.first?.kind, FolderConflict.Kind.empty)
    }
}
