import XCTest
@testable import MacDroidSyncCore

/// The file name arrives from the phone, so most of these tests are about not
/// trusting it, and the rest about never publishing a file that did not arrive
/// complete.
final class FileReceiverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Names

    func testSanitizeStripsDirectoriesAndDots() {
        XCTAssertEqual(FileReceiver.sanitize(name: "../../etc/passwd"), "passwd")
        XCTAssertEqual(FileReceiver.sanitize(name: "/absolute/path/report.pdf"), "report.pdf")
        XCTAssertEqual(FileReceiver.sanitize(name: "..\\Windows\\evil.exe"), "evil.exe")
        XCTAssertEqual(FileReceiver.sanitize(name: ".."), "file")
        XCTAssertEqual(FileReceiver.sanitize(name: ""), "file")
        XCTAssertEqual(FileReceiver.sanitize(name: "   "), "file")
        XCTAssertEqual(FileReceiver.sanitize(name: ".hidden"), "hidden")
        XCTAssertEqual(FileReceiver.sanitize(name: "with\u{0}control\nchars.txt"), "withcontrolchars.txt")
        XCTAssertEqual(FileReceiver.sanitize(name: "a:b.txt"), "ab.txt")
        XCTAssertEqual(FileReceiver.sanitize(name: "holiday photo.jpg"), "holiday photo.jpg")
    }

    func testSanitizeCapsTheLengthButKeepsTheExtension() {
        let long = String(repeating: "x", count: 400) + ".jpeg"
        let sanitized = FileReceiver.sanitize(name: long)
        XCTAssertEqual(sanitized.count, 200)
        XCTAssertTrue(sanitized.hasSuffix(".jpeg"))
    }

    // MARK: - Transfers

    func testCompleteTransferLandsInTheDirectory() throws {
        let receiver = FileReceiver(directory: directory)
        let payload = Data("MacDroidSync file transfer v1".utf8)

        try receiver.begin(offer(name: "note.txt", size: Int64(payload.count)))
        try receiver.append(payload.prefix(10))
        try receiver.append(payload.dropFirst(10))
        XCTAssertEqual(receiver.receivedBytes, Int64(payload.count))

        // The digest is also the cross platform vector from PROTOCOL.md.
        let url = try receiver.finish(sha256: "4f3a7edaac1dc9e52ee41243f6f5d0dec1229bea078dde437c84054b019901c3")

        XCTAssertEqual(url.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try leftovers(), ["note.txt"], "no partial files may be left behind")
    }

    func testUppercaseChecksumIsAccepted() throws {
        let receiver = FileReceiver(directory: directory)
        let payload = Data("MacDroidSync file transfer v1".utf8)
        try receiver.begin(offer(name: "note.txt", size: Int64(payload.count)))
        try receiver.append(payload)
        XCTAssertNoThrow(try receiver.finish(
            sha256: "4F3A7EDAAC1DC9E52EE41243F6F5D0DEC1229BEA078DDE437C84054B019901C3"
        ))
    }

    func testSecondFileWithTheSameNameGetsASuffix() throws {
        let receiver = FileReceiver(directory: directory)
        for _ in 0 ..< 2 {
            try receiver.begin(offer(name: "photo.jpg", size: 3))
            try receiver.append(Data([1, 2, 3]))
            _ = try receiver.finish(sha256: nil)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["photo (2).jpg", "photo.jpg"])
    }

    func testChecksumMismatchDiscardsTheFile() throws {
        let receiver = FileReceiver(directory: directory)
        try receiver.begin(offer(name: "photo.jpg", size: 3))
        try receiver.append(Data([1, 2, 3]))

        XCTAssertThrowsError(try receiver.finish(sha256: String(repeating: "0", count: 64))) { error in
            guard case FileTransferError.checksumMismatch = error else {
                return XCTFail("expected a checksum mismatch, got \(error)")
            }
        }
        XCTAssertEqual(try leftovers(), [])
    }

    func testSizeMismatchDiscardsTheFile() throws {
        let receiver = FileReceiver(directory: directory)
        try receiver.begin(offer(name: "photo.jpg", size: 10))
        try receiver.append(Data([1, 2, 3]))

        XCTAssertThrowsError(try receiver.finish(sha256: nil)) { error in
            guard case FileTransferError.sizeMismatch(let expected, let received) = error else {
                return XCTFail("expected a size mismatch, got \(error)")
            }
            XCTAssertEqual(expected, 10)
            XCTAssertEqual(received, 3)
        }
        XCTAssertEqual(try leftovers(), [])
    }

    func testOfferAboveTheLimitIsRefused() {
        let receiver = FileReceiver(directory: directory)
        XCTAssertThrowsError(try receiver.begin(offer(name: "huge.zip", size: Wire.maxFileBytes + 1))) { error in
            guard case FileTransferError.tooLarge = error else {
                return XCTFail("expected the size limit to trigger, got \(error)")
            }
        }
        XCTAssertEqual(try? leftovers(), [])
    }

    func testAbortRemovesThePartialFile() throws {
        let receiver = FileReceiver(directory: directory)
        try receiver.begin(offer(name: "movie.mp4", size: 1_000))
        try receiver.append(Data(repeating: 7, count: 100))
        XCTAssertEqual(try leftovers().count, 1, "the partial file exists while receiving")

        receiver.abort()
        XCTAssertEqual(try leftovers(), [])
        XCTAssertEqual(receiver.receivedBytes, 0)
    }

    func testANewOfferReplacesAnUnfinishedOne() throws {
        let receiver = FileReceiver(directory: directory)
        try receiver.begin(offer(name: "first.bin", size: 100))
        try receiver.append(Data(repeating: 1, count: 10))

        try receiver.begin(offer(name: "second.bin", size: 2))
        try receiver.append(Data([9, 9]))
        let url = try receiver.finish(sha256: nil)

        XCTAssertEqual(url.lastPathComponent, "second.bin")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["second.bin"])
    }

    func testChunkWithoutAnOfferIsRefused() {
        let receiver = FileReceiver(directory: directory)
        XCTAssertThrowsError(try receiver.append(Data([1]))) { error in
            guard case FileTransferError.noTransferInProgress = error else {
                return XCTFail("expected no transfer in progress, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func offer(name: String, size: Int64) -> FileOffer {
        FileOffer(id: UUID().uuidString, name: name, size: size, mime: "application/octet-stream")
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
