import XCTest
@testable import MacDroidSyncCore

final class LocalFolderTests: XCTestCase {
    /// The Finder's .DS_Store among the notes of a folder: it stays out, and every note after it is still seen.
    func testAFileLeftOutHidesNothingAfterIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFolderTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Firma", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".Trashes", isDirectory: true), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".Trashes/hidden.md"))
        let names = [".DS_Store", "AI.md", "AP.md", "Clouds.md", "VS.md", "Zeszyt.md"]
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let past = Date(timeIntervalSinceNow: -60)
        let scan = LocalFolder(root: root, settleWrites: 3, useTrash: false).scan(cache: [:], now: past.addingTimeInterval(3600))
        let files = Set(scan.entries.filter { !$0.isDirectory }.map(\.p))
        XCTAssertEqual(files, Set(names.dropFirst().map { "Firma/" + $0 }))
    }
}
