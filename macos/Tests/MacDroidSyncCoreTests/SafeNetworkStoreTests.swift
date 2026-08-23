import CoreLocation
import XCTest
@testable import MacDroidSyncCore

/// The list of networks on which the Mac stands down.
///
/// Every test here is about the same question asked from a different side: when
/// in doubt, does this feature keep locking? A bug that adds a lock is an
/// annoyance; a bug that removes one is a Mac left open.
final class SafeNetworkStoreTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    private let home = "c5bd1be4e7388136c95cbfe16be2a4228e76e6d7f85d26fd2577a0cfcc60e663"
    private let cafe = "9f13a0c2b4e5d6789abcdef0123456789abcdef0123456789abcdef012345678"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncNetworks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("safe-networks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    func testNoNetworkIsNeverSafe() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: home)

        // Wi-Fi off, Ethernet only, or a network macOS would not name: all three
        // arrive here as nil, and none of them may switch the auto lock off.
        XCTAssertFalse(store.isSafe(nil))
        XCTAssertFalse(store.isSafe(""))
        XCTAssertTrue(store.isSafe(home))
    }

    func testOnlyTheNetworksOnTheListAreSafe() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: home)

        XCTAssertTrue(store.isSafe(home))
        XCTAssertFalse(store.isSafe(cafe))
    }

    func testAddingTheSameNetworkTwiceChangesNothing() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: home)
        let firstSeen = store.all.first?.ts

        store.add(id: home)

        XCTAssertEqual(store.count, 1)
        // The same entry, so it keeps the moment it was added.
        XCTAssertEqual(store.all.first?.ts, firstSeen)
    }

    func testAnEmptyIdentityIsNotAcceptedAtAll() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: "")

        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.isSafe(""))
    }

    func testRemovingANetworkBringsTheLockBack() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: home)
        store.add(id: cafe)

        store.remove(id: home)

        XCTAssertFalse(store.isSafe(home))
        XCTAssertTrue(store.isSafe(cafe))
        XCTAssertEqual(store.count, 1)
    }

    func testTheListSurvivesARestart() {
        let store = SafeNetworkStore(url: storeURL)
        store.add(id: home)
        store.add(id: cafe)

        let reopened = SafeNetworkStore(url: storeURL)

        XCTAssertEqual(reopened.all.map(\.id), [home, cafe])
        XCTAssertTrue(reopened.isSafe(home))
    }

    func testAnUnreadableFileMeansEveryNetworkIsUnsafe() throws {
        try Data("this is not the list".utf8).write(to: storeURL)

        let store = SafeNetworkStore(url: storeURL)

        // A damaged file must not read as "every network is trusted": that would
        // turn a broken file into a silently disabled auto lock.
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.isSafe(home))
    }
}

/// The poll behind the safe networks: it has to report a change once, and stay
/// quiet while nothing changes.
final class NetworkMonitorTests: XCTestCase {

    func testAChangeIsReportedOnceAndSilenceIsKept() {
        var current: String? = "one"
        let monitor = NetworkMonitor(interval: 0.02) { current }
        var seen: [String?] = []

        let changed = expectation(description: "the change is reported")
        monitor.onChange = { value in
            seen.append(value)
            if seen.count == 2 { changed.fulfill() }
        }
        monitor.start()
        XCTAssertEqual(monitor.currentProfileID, "one")

        current = "two"
        // Two distinct changes, with several polls in between that must say nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { current = nil }

        wait(for: [changed], timeout: 2)
        monitor.stop()

        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.first, "two")
        XCTAssertNil(seen.last ?? "still set")
    }

    func testStoppingEndsThePoll() {
        var reads = 0
        let monitor = NetworkMonitor(interval: 0.02) { reads += 1; return "\(reads)" }
        monitor.start()
        monitor.stop()
        let after = reads

        let settled = expectation(description: "no further reads")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(reads, after)
    }
}

/// The log has to make a roaming test possible without revealing much.
final class NetworkMonitorDescriptionTests: XCTestCase {

    func testTheIdentityIsShortenedButStillDistinguishing() {
        XCTAssertEqual(
            NetworkMonitor.describe("c5bd1be4e7388136c95cbfe16be2a422"),
            "on Wi-Fi network c5bd1be4…"
        )
        XCTAssertNotEqual(
            NetworkMonitor.describe("c5bd1be4e7388136"),
            NetworkMonitor.describe("9f13a0c2b4e5d678")
        )
    }

    func testNoNetworkSaysSo() {
        XCTAssertEqual(NetworkMonitor.describe(nil), "on no Wi-Fi network")
        XCTAssertEqual(NetworkMonitor.describe(""), "on no Wi-Fi network")
    }
}

/// How an identity is put in front of a person.
final class NetworkShortFormTests: XCTestCase {

    func testBothEndsAreKept() {
        // Two networks differing only in the middle must not look identical, so
        // the tail is kept as well as the head.
        let one = CurrentNetwork.shortForm("c5bd1be4e7388136c95cbfe16be2a4228e76e6d7f85d26fd2577a0cfcc60e663")
        let two = CurrentNetwork.shortForm("c5bd1be4e7000000000000000000000000000000000000000000000000e60000")
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(one.hasPrefix("c5bd1be4e7"))
        XCTAssertTrue(one.hasSuffix("cc60e663"))
    }

    func testShortIdentitiesAreLeftAlone() {
        XCTAssertEqual(CurrentNetwork.shortForm("abc123"), "abc123")
    }
}
