import XCTest
@testable import MacDroidSyncCore

/// The queue of files waiting for the phone: it has to survive a restart and it
/// must not get stuck on a file the user moved away in the meantime.
final class OutboxStoreTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncOutbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("outbox.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    func testQueueKeepsTheOrderAndSurvivesAReload() throws {
        let first = try file(named: "one.txt")
        let second = try file(named: "two.txt")

        let store = OutboxStore(url: storeURL)
        store.enqueue([first, second])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.all.map(\.name), ["one.txt", "two.txt"])

        // A fresh instance stands for the app being restarted.
        let reloaded = OutboxStore(url: storeURL)
        XCTAssertEqual(reloaded.all.map(\.name), ["one.txt", "two.txt"])
        XCTAssertEqual(reloaded.first()?.name, "one.txt")
    }

    func testRemovingTheHeadMovesToTheNextFile() throws {
        let first = try file(named: "one.txt")
        let second = try file(named: "two.txt")
        let store = OutboxStore(url: storeURL)
        store.enqueue([first, second])

        let head = try XCTUnwrap(store.first())
        store.remove(id: head.id)
        XCTAssertEqual(store.first()?.name, "two.txt")
        XCTAssertEqual(store.count, 1)
    }

    func testVanishedFilesAreDroppedAndReported() throws {
        let gone = try file(named: "gone.txt")
        let kept = try file(named: "kept.txt")
        let store = OutboxStore(url: storeURL)
        store.enqueue([gone, kept])
        try FileManager.default.removeItem(at: gone)

        var reported: [String] = []
        let head = store.first { reported.append($0.name) }

        XCTAssertEqual(head?.name, "kept.txt")
        XCTAssertEqual(reported, ["gone.txt"])
        XCTAssertEqual(store.count, 1, "the missing entry must not come back")
        XCTAssertEqual(OutboxStore(url: storeURL).count, 1, "and it must not come back after a reload either")
    }

    func testEmptyQueueLeavesNoFileBehind() throws {
        let store = OutboxStore(url: storeURL)
        store.enqueue([try file(named: "one.txt")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        store.clear()
        XCTAssertNil(store.first())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    private func file(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
}

/// Where the shared state lives. The Share extension runs sandboxed, so this is
/// the one thing that must never be derived from the container relative APIs:
/// doing that silently sent every shared file into
/// ~/Library/Containers/…/Application Support, where the app never looks.
final class AppPathsTests: XCTestCase {
    func testSupportDirectorySitsUnderTheRealHome() {
        let home = AppPaths.homeDirectory.path
        XCTAssertFalse(home.contains("/Library/Containers/"), "getpwuid must report the real home")
        XCTAssertEqual(
            AppPaths.supportDirectory.path,
            home + "/Library/Application Support/MacDroidSync"
        )
        XCTAssertTrue(ShareInbox.defaultDirectory.path.hasPrefix(AppPaths.supportDirectory.path))
    }
}

/// The drop box the sandboxed Share extension writes into.
final class ShareInboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncInbox-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testRequestsRoundTripAndAreConsumedOnce() {
        let first = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        let second = [URL(fileURLWithPath: "/tmp/c.txt")]

        XCTAssertTrue(ShareInbox.write(paths: first, in: directory))
        XCTAssertTrue(ShareInbox.write(paths: second, in: directory))

        let taken = ShareInbox.takeAll(in: directory)
        XCTAssertEqual(taken.map(\.path), ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"])
        XCTAssertTrue(ShareInbox.takeAll(in: directory).isEmpty, "a request is delivered exactly once")
    }

    func testEmptyRequestIsNotWritten() {
        XCTAssertFalse(ShareInbox.write(paths: [], in: directory))
        XCTAssertTrue(ShareInbox.takeAll(in: directory).isEmpty)
    }

    func testHalfWrittenRequestIsIgnoredUntilItIsRenamed() throws {
        ShareInbox.ensureDirectory(directory)
        // The extension writes under a .writing name first, exactly so that this
        // is invisible to the app.
        let partial = directory.appendingPathComponent("1700000000000-partial.json.writing")
        try Data("{\"paths\":[\"/tmp/x\"],\"ts\":1}".utf8).write(to: partial)

        XCTAssertTrue(ShareInbox.takeAll(in: directory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "and it must not be deleted either")
    }

    func testUnreadableRequestIsDiscarded() throws {
        ShareInbox.ensureDirectory(directory)
        let broken = directory.appendingPathComponent("1700000000000-broken.json")
        try Data("not json".utf8).write(to: broken)

        XCTAssertTrue(ShareInbox.takeAll(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
    }

    func testWatcherFiresWhenARequestArrives() throws {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = ShareInbox.watch(directory, queue: .global()) { fired.fulfill() }
        XCTAssertNotNil(watcher)
        defer { watcher?.cancel() }

        ShareInbox.write(paths: [URL(fileURLWithPath: "/tmp/a.txt")], in: directory)
        wait(for: [fired], timeout: 5)
    }
}
