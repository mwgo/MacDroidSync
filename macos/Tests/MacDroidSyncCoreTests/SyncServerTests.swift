import CryptoKit
import Network
import XCTest
@testable import MacDroidSyncCore

/// Drives the real server over a real socket with a minimal client, so the
/// handshake, the clipboard exchange, the ping round trip and the state
/// transitions are covered without any UI.
final class SyncServerTests: XCTestCase {
    private var server: SyncServer!
    private var configuration: TestConfiguration!
    private var downloads: URL!

    override func setUp() {
        super.setUp()
        configuration = TestConfiguration(port: Self.freePort(), pairingCode: "TEST-PAIR-CODE-0001")
        downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncServerTests-\(UUID().uuidString)")
        server = SyncServer(settings: configuration, destinationDirectory: downloads)
    }

    override func tearDown() {
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: downloads)
        downloads = nil
        super.tearDown()
    }

    func testHandshakeClipboardAndPing() throws {
        let listening = expectation(description: "listener ready")
        let connected = expectation(description: "authenticated")
        var states: [PeerState] = []
        server.onListening = { port in
            XCTAssertEqual(port, self.configuration.port)
            listening.fulfill()
        }
        server.onStateChange = { state in
            states.append(state)
            if state == .connected { connected.fulfill() }
        }

        let clipboardFromPhone = expectation(description: "clipboard from the phone")
        server.onClipboardReceived = { text in
            XCTAssertEqual(text, "from the phone")
            clipboardFromPhone.fulfill()
        }
        let roundTrip = expectation(description: "ping round trip")
        server.onRoundTrip = { milliseconds in
            XCTAssertGreaterThanOrEqual(milliseconds, 0)
            XCTAssertLessThan(milliseconds, 5_000)
            roundTrip.fulfill()
        }

        server.start()
        wait(for: [listening], timeout: 5)

        let peer = TestPeer(port: configuration.port, pairingCode: configuration.pairingCode)
        let clipboardToPhone = expectation(description: "clipboard delivered to the phone")
        peer.onMessage = { message in
            if message.type == MessageType.clipboard, message.text == "from the Mac" {
                clipboardToPhone.fulfill()
            }
        }
        peer.start()
        wait(for: [connected], timeout: 5)
        XCTAssertEqual(server.connectedDeviceName, "Test Phone")
        XCTAssertEqual(configuration.pairedDeviceName, "Test Phone")

        XCTAssertTrue(server.sendClipboard(text: "from the Mac"))
        wait(for: [clipboardToPhone], timeout: 5)

        peer.send(type: MessageType.clipboard, text: "from the phone")
        wait(for: [clipboardFromPhone], timeout: 5)

        XCTAssertTrue(server.ping())
        wait(for: [roundTrip], timeout: 5)

        let disconnected = expectation(description: "back to disconnected")
        server.onStateChange = { if $0 == .disconnected { disconnected.fulfill() } }
        peer.close()
        wait(for: [disconnected], timeout: 5)

        XCTAssertFalse(server.isConnected)
        XCTAssertFalse(server.sendClipboard(text: "nobody is listening"), "queueing is the caller's job")
        XCTAssertEqual(states.prefix(2).map(\.rawValue), ["connecting", "connected"])
    }

    func testWrongPairingCodeIsRejected() throws {
        let listening = expectation(description: "listener ready")
        server.onListening = { _ in listening.fulfill() }
        server.start()
        wait(for: [listening], timeout: 5)

        let peer = TestPeer(port: configuration.port, pairingCode: "WRONG-CODE-9999-0000")
        peer.start()

        // The server must never reach the connected state with a bad code.
        let stayedOut = expectation(description: "not authenticated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            XCTAssertFalse(self.server.isConnected)
            XCTAssertNil(self.server.connectedDeviceName)
            stayedOut.fulfill()
        }
        wait(for: [stayedOut], timeout: 5)
        peer.close()
    }

    func testSuspendSaysGoodbyeAndResumeAcceptsAgain() throws {
        let listening = expectation(description: "listener ready")
        server.onListening = { _ in listening.fulfill() }
        let connected = expectation(description: "authenticated")
        server.onStateChange = { if $0 == .connected { connected.fulfill() } }
        server.start()
        wait(for: [listening], timeout: 5)

        let peer = TestPeer(port: configuration.port, pairingCode: configuration.pairingCode)
        let goodbye = expectation(description: "peer is told why the sync stops")
        peer.onMessage = { message in
            if message.type == MessageType.bye {
                XCTAssertEqual(message.reason, "the lid is closed")
                goodbye.fulfill()
            }
        }
        peer.start()
        wait(for: [connected], timeout: 5)

        let suspended = expectation(description: "suspended state")
        server.onStateChange = { if $0 == .suspended { suspended.fulfill() } }
        server.suspend(reason: "the lid is closed")
        wait(for: [goodbye, suspended], timeout: 5)
        XCTAssertFalse(server.isConnected)
        XCTAssertNil(server.connectedDeviceName)
        peer.close()

        // While suspended nothing is served, so a new peer cannot get in.
        let listeningAgain = expectation(description: "listener back up")
        server.onListening = { _ in listeningAgain.fulfill() }
        let reconnected = expectation(description: "authenticated again")
        server.onStateChange = { if $0 == .connected { reconnected.fulfill() } }

        server.resume()
        wait(for: [listeningAgain], timeout: 5)

        let second = TestPeer(port: configuration.port, pairingCode: configuration.pairingCode)
        second.start()
        wait(for: [reconnected], timeout: 5)
        XCTAssertTrue(server.isConnected)
        second.close()
    }

    func testFileFromThePhoneLandsInTheDestinationDirectory() throws {
        let peer = try connectedPeer()

        // Two chunks on purpose: the receiver has to stitch them back together.
        let payload = Data((0 ..< 5_000).map { UInt8($0 % 251) })
        let digest = payload.sha256Hex

        let received = expectation(description: "file received")
        var savedURL: URL?
        server.onFileReceived = { url, name in
            XCTAssertEqual(name, "holiday.bin")
            savedURL = url
            received.fulfill()
        }
        let acknowledged = expectation(description: "phone told the transfer succeeded")
        peer.onMessage = { message in
            guard message.type == MessageType.fileAck else { return }
            XCTAssertEqual(message.ok, true)
            XCTAssertEqual(message.name, "holiday.bin")
            XCTAssertNotNil(message.path)
            acknowledged.fulfill()
        }

        peer.send(type: MessageType.fileOffer, fileId: "f1", name: "holiday.bin", size: Int64(payload.count), mime: "application/octet-stream")
        peer.send(type: MessageType.fileChunk, fileId: "f1", data: payload.prefix(3_000).base64EncodedString())
        peer.send(type: MessageType.fileChunk, fileId: "f1", data: payload.dropFirst(3_000).base64EncodedString())
        peer.send(type: MessageType.fileEnd, fileId: "f1", sha256: digest)

        wait(for: [received, acknowledged], timeout: 10)
        let url = try XCTUnwrap(savedURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, downloads.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: downloads.path),
            ["holiday.bin"],
            "nothing partial may survive a successful transfer"
        )
        peer.close()
    }

    func testCorruptedFileIsRefusedAndLeavesNothingBehind() throws {
        let peer = try connectedPeer()

        let failed = expectation(description: "transfer reported as failed")
        server.onFileFailed = { name, reason in
            XCTAssertEqual(name, "broken.bin")
            XCTAssertFalse(reason.isEmpty)
            failed.fulfill()
        }
        let refused = expectation(description: "phone told the transfer failed")
        peer.onMessage = { message in
            guard message.type == MessageType.fileAck else { return }
            XCTAssertEqual(message.ok, false)
            XCTAssertNil(message.path)
            refused.fulfill()
        }

        peer.send(type: MessageType.fileOffer, fileId: "f2", name: "broken.bin", size: 3)
        peer.send(type: MessageType.fileChunk, fileId: "f2", data: Data([1, 2, 3]).base64EncodedString())
        peer.send(type: MessageType.fileEnd, fileId: "f2", sha256: String(repeating: "0", count: 64))

        wait(for: [failed, refused], timeout: 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
        peer.close()
    }

    func testOversizedOfferIsRefusedBeforeAnyBytesArrive() throws {
        let peer = try connectedPeer()

        let refused = expectation(description: "offer refused")
        peer.onMessage = { message in
            guard message.type == MessageType.fileAck else { return }
            XCTAssertEqual(message.ok, false)
            refused.fulfill()
        }
        peer.send(type: MessageType.fileOffer, fileId: "f3", name: "huge.zip", size: Wire.maxFileBytes + 1)

        wait(for: [refused], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("huge.zip").path))
        peer.close()
    }

    func testFileSentToThePhoneArrivesComplete() throws {
        let peer = try connectedPeer()

        let payload = Data((0 ..< (Wire.fileChunkBytes * 2 + 777)).map { UInt8($0 % 251) })
        let source = try temporaryFile(named: "from-the-mac.bin", contents: payload)

        let arrived = expectation(description: "the phone assembled the file")
        peer.onFileComplete = { name, data, checksum in
            XCTAssertEqual(name, "from-the-mac.bin")
            XCTAssertEqual(data, payload)
            XCTAssertEqual(checksum, payload.sha256Hex, "the checksum must cover the whole file")
            arrived.fulfill()
        }
        let confirmed = expectation(description: "the Mac learned it was saved")
        server.onFileSent = { name, path in
            XCTAssertEqual(name, "from-the-mac.bin")
            XCTAssertEqual(path, "Download/from-the-mac.bin")
            confirmed.fulfill()
        }

        XCTAssertTrue(try server.sendFile(url: source))
        wait(for: [arrived, confirmed], timeout: 15)
        XCTAssertFalse(server.isSendingFile, "the session is free for the next file")
        XCTAssertEqual(peer.fileEndCount, 1, "file-end must be sent exactly once")
        peer.close()
    }

    func testPhoneRefusalStopsTheTransfer() throws {
        let peer = try connectedPeer()
        peer.refuseFiles = true

        // Big enough that stopping early is visible in the byte count.
        let payload = Data(repeating: 7, count: Wire.fileChunkBytes * 20)
        let source = try temporaryFile(named: "unwanted.bin", contents: payload)

        let refused = expectation(description: "the Mac was told no")
        server.onFileSendFailed = { name, reason in
            XCTAssertEqual(name, "unwanted.bin")
            XCTAssertEqual(reason, "the phone has no room")
            refused.fulfill()
        }

        XCTAssertTrue(try server.sendFile(url: source))
        wait(for: [refused], timeout: 15)
        XCTAssertLessThan(peer.receivedFileBytes, payload.count, "the remaining chunks must not be sent")
        XCTAssertFalse(server.isSendingFile)
        peer.close()
    }

    func testSendingAMissingFileFailsBeforeAnythingIsSent() throws {
        let peer = try connectedPeer()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDroidSyncMissing-\(UUID().uuidString).bin")

        XCTAssertThrowsError(try server.sendFile(url: missing)) { error in
            guard case FileTransferError.missingFile = error else {
                return XCTFail("expected a missing file, got \(error)")
            }
        }
        XCTAssertFalse(server.isSendingFile)
        peer.close()
    }

    func testNothingIsSentWithoutAPhone() throws {
        let listening = expectation(description: "listener ready")
        server.onListening = { _ in listening.fulfill() }
        server.start()
        wait(for: [listening], timeout: 5)

        let source = try temporaryFile(named: "queued.bin", contents: Data([1, 2, 3]))
        XCTAssertFalse(try server.sendFile(url: source), "queueing is the caller's job")
    }

    func testClamshellStateIsReadable() {
        // Nil on a desktop Mac, a real value on anything with a lid: either way
        // this must not throw or hang.
        let closed = PowerMonitor.isClamshellClosed()
        Log.info("Clamshell state during the test: \(String(describing: closed))")
    }

    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let url = downloads.appendingPathComponent("outgoing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try contents.write(to: file)
        return file
    }

    /// Starts the server, connects a peer and returns once the handshake is done.
    private func connectedPeer() throws -> TestPeer {
        let listening = expectation(description: "listener ready")
        server.onListening = { _ in listening.fulfill() }
        let connected = expectation(description: "authenticated")
        server.onStateChange = { if $0 == .connected { connected.fulfill() } }

        server.start()
        wait(for: [listening], timeout: 5)

        let peer = TestPeer(port: configuration.port, pairingCode: configuration.pairingCode)
        peer.start()
        wait(for: [connected], timeout: 5)
        return peer
    }

    /// Asks the kernel for an unused port so parallel runs do not collide.
    private static func freePort() -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        withUnsafePointer(to: &address) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(handle, $0, &length)
            }
        }
        return UInt16(bigEndian: bound.sin_port)
    }
}

private final class TestConfiguration: SyncConfiguration {
    let port: UInt16
    let pairingCode: String
    let deviceName = "Test Mac"
    let deviceId = "test-mac-1"
    var pairedDeviceName: String?

    init(port: UInt16, pairingCode: String) {
        self.port = port
        self.pairingCode = pairingCode
    }
}

/// Minimal stand-in for the Android client: answers the challenge and reports
/// every message it receives.
private final class TestPeer {
    var onMessage: ((Message) -> Void)?
    /// Name, bytes and checksum of a file the Mac sent us.
    var onFileComplete: ((String, Data, String?) -> Void)?
    /// Turns every offer down, like a phone with no space left.
    var refuseFiles = false

    private(set) var receivedFileBytes = 0
    private(set) var fileEndCount = 0
    private var incomingName: String?
    private var incomingData = Data()

    private let codec: FrameCodec
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.peer")
    private var buffer = Data()

    init(port: UInt16, pairingCode: String) {
        self.codec = FrameCodec(pairingCode: pairingCode)
        self.connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func start() {
        receive()
        connection.start(queue: queue)
    }

    func close() {
        connection.cancel()
    }

    func send(
        type: String,
        text: String? = nil,
        challenge: String? = nil,
        token: UInt64? = nil,
        fileId: String? = nil,
        name: String? = nil,
        size: Int64? = nil,
        mime: String? = nil,
        sha256: String? = nil,
        data: String? = nil,
        ok: Bool? = nil,
        path: String? = nil,
        reason: String? = nil
    ) {
        let message = Message(
            seq: codec.nextSequence(),
            type: type,
            text: text,
            device: "Test Phone",
            deviceId: "test-phone-1",
            challenge: challenge,
            token: token,
            reason: reason,
            fileId: fileId,
            name: name,
            size: size,
            mime: mime,
            sha256: sha256,
            data: data,
            ok: ok,
            path: path
        )
        guard let body = try? codec.seal(try message.encoded()) else { return }
        connection.send(content: Framing.frame(kind: .encrypted, body: body), completion: .idempotent)
    }

    /// Minimal receiving side of the file protocol, enough to check that the Mac
    /// sends a complete and correct file.
    private func handleFileMessage(_ message: Message) {
        switch message.type {
        case MessageType.fileOffer:
            guard !refuseFiles else {
                send(type: MessageType.fileAck, fileId: message.fileId, name: message.name, ok: false, reason: "the phone has no room")
                return
            }
            incomingName = message.name
            incomingData = Data()
            receivedFileBytes = 0
        case MessageType.fileChunk:
            guard let encoded = message.data, let chunk = Data(base64Encoded: encoded) else { return }
            incomingData.append(chunk)
            receivedFileBytes = incomingData.count
        case MessageType.fileEnd:
            fileEndCount += 1
            guard let name = incomingName else { return }
            let data = incomingData
            incomingName = nil
            incomingData = Data()
            send(
                type: MessageType.fileAck,
                fileId: message.fileId,
                name: name,
                ok: true,
                path: "Download/\(name)"
            )
            onFileComplete?(name, data, message.sha256)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let frame = try? Framing.nextFrame(from: &self.buffer) {
                    switch frame.kind {
                    case .plaintext:
                        guard let message = try? Message.decode(frame.body) else { continue }
                        self.onMessage?(message)
                        if message.type == MessageType.challenge {
                            self.send(type: MessageType.hello, challenge: message.challenge)
                        }
                    case .encrypted:
                        guard let message = try? self.codec.open(frame.body) else { continue }
                        self.onMessage?(message)
                        if message.type == MessageType.clipboard {
                            self.send(type: MessageType.clipboardAck)
                        }
                        if message.type == MessageType.ping {
                            self.send(type: MessageType.pong, token: message.token)
                        }
                        self.handleFileMessage(message)
                    }
                }
            }
            if error != nil || isComplete { return }
            self.receive()
        }
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
