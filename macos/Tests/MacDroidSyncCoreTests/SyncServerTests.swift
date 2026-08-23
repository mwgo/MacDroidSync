import Network
import XCTest
@testable import MacDroidSyncCore

/// Drives the real server over a real socket with a minimal client, so the
/// handshake, the clipboard exchange, the ping round trip and the state
/// transitions are covered without any UI.
final class SyncServerTests: XCTestCase {
    private var server: SyncServer!
    private var configuration: TestConfiguration!

    override func setUp() {
        super.setUp()
        configuration = TestConfiguration(port: Self.freePort(), pairingCode: "TEST-PAIR-CODE-0001")
        server = SyncServer(settings: configuration)
    }

    override func tearDown() {
        server.stop()
        server = nil
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

    func testClamshellStateIsReadable() {
        // Nil on a desktop Mac, a real value on anything with a lid: either way
        // this must not throw or hang.
        let closed = PowerMonitor.isClamshellClosed()
        Log.info("Clamshell state during the test: \(String(describing: closed))")
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

    func send(type: String, text: String? = nil, challenge: String? = nil, token: UInt64? = nil) {
        let message = Message(
            seq: codec.nextSequence(),
            type: type,
            text: text,
            device: "Test Phone",
            deviceId: "test-phone-1",
            challenge: challenge,
            token: token
        )
        guard let body = try? codec.seal(try message.encoded()) else { return }
        connection.send(content: Framing.frame(kind: .encrypted, body: body), completion: .idempotent)
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
                    }
                }
            }
            if error != nil || isComplete { return }
            self.receive()
        }
    }
}
