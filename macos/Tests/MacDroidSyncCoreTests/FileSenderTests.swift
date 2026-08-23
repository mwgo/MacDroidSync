import CryptoKit
import XCTest
@testable import MacDroidSyncCore

/// The outgoing half of a file transfer: slicing, hashing and refusing what
/// cannot be sent at all.
final class FileSenderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncSender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testChunksCoverTheWholeFileAndHashMatches() throws {
        // Two and a bit chunks, so the last one is deliberately short.
        let payload = Data((0 ..< (Wire.fileChunkBytes * 2 + 1_234)).map { UInt8($0 % 251) })
        let file = directory.appendingPathComponent("holiday.bin")
        try payload.write(to: file)

        let sender = try FileSender(url: file)
        XCTAssertEqual(sender.name, "holiday.bin")
        XCTAssertEqual(sender.size, Int64(payload.count))

        var rebuilt = Data()
        var chunks = 0
        while let chunk = try sender.nextChunk() {
            XCTAssertLessThanOrEqual(chunk.count, Wire.fileChunkBytes)
            rebuilt.append(chunk)
            chunks += 1
        }
        XCTAssertEqual(chunks, 3)
        XCTAssertEqual(rebuilt, payload)
        XCTAssertEqual(sender.sentBytes, Int64(payload.count))
        XCTAssertEqual(sender.checksum(), SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(try sender.nextChunk(), "the reader must stay finished")
        sender.close()
    }

    func testChecksumMatchesTheProtocolVector() throws {
        let file = directory.appendingPathComponent("note.txt")
        try Data("MacDroidSync file transfer v1".utf8).write(to: file)

        let sender = try FileSender(url: file)
        while try sender.nextChunk() != nil {}
        XCTAssertEqual(sender.checksum(), "4f3a7edaac1dc9e52ee41243f6f5d0dec1229bea078dde437c84054b019901c3")
        sender.close()
    }

    func testEmptyFileIsStillSendable() throws {
        let file = directory.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        let sender = try FileSender(url: file)
        XCTAssertEqual(sender.size, 0)
        XCTAssertNil(try sender.nextChunk())
        XCTAssertEqual(sender.checksum(), SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
        sender.close()
    }

    func testMimeTypeComesFromTheExtension() throws {
        let file = directory.appendingPathComponent("photo.jpeg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        XCTAssertEqual(try FileSender(url: file).mime, "image/jpeg")
    }

    func testMissingFileIsRefused() {
        let missing = directory.appendingPathComponent("gone.bin")
        XCTAssertThrowsError(try FileSender(url: missing)) { error in
            guard case FileTransferError.missingFile = error else {
                return XCTFail("expected a missing file, got \(error)")
            }
        }
    }

    func testDirectoryIsRefused() {
        XCTAssertThrowsError(try FileSender(url: directory)) { error in
            guard case FileTransferError.notAFile = error else {
                return XCTFail("expected a folder to be refused, got \(error)")
            }
        }
    }

    func testFileAboveTheLimitIsRefused() throws {
        // A sparse file keeps the test cheap while still being over the limit.
        let file = directory.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(Wire.maxFileBytes) + 1)
        try handle.close()

        XCTAssertThrowsError(try FileSender(url: file)) { error in
            guard case FileTransferError.tooLarge = error else {
                return XCTFail("expected the size limit to trigger, got \(error)")
            }
        }
    }
}
