import Foundation
import Network

/// State of the connection, mirrored by the menu bar icon.
public enum PeerState: String {
    case disconnected
    case connecting
    case connected
    case transferring
    /// Deliberately stopped, currently only while the Mac sleeps or its lid is closed.
    case suspended
    case error
}

/// One accepted TCP connection: handshake, framing, heartbeat and liveness.
/// Every callback is invoked on the session queue.
public final class PeerSession {
    public var onAuthenticated: ((String) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onClipboardAck: (() -> Void)?
    public var onClipboardRequested: (() -> Void)?
    public var onRoundTrip: ((Double) -> Void)?
    public var onEnd: ((Error?) -> Void)?

    public private(set) var remoteDeviceName: String?
    public private(set) var isAuthenticated = false

    private let connection: NWConnection
    private let codec: FrameCodec
    private let localDeviceName: String
    private let localDeviceId: String
    private let queue: DispatchQueue

    private var buffer = Data()
    private var challenge = Data()
    private var lastReceive = Date()
    private var lastSend = Date()
    private var pendingPings: [UInt64: Date] = [:]
    private var timer: DispatchSourceTimer?
    private var isClosed = false

    public init(
        connection: NWConnection,
        pairingCode: String,
        localDeviceName: String,
        localDeviceId: String,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.codec = FrameCodec(pairingCode: pairingCode)
        self.localDeviceName = localDeviceName
        self.localDeviceId = localDeviceId
        self.queue = queue
    }

    public var remoteDescription: String {
        switch connection.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        default: return String(describing: connection.endpoint)
        }
    }

    // MARK: - Lifecycle

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("Connection ready: \(self.remoteDescription)")
                self.sendChallenge()
            case .failed(let error):
                self.finish(error: error)
            case .cancelled:
                self.finish(error: nil)
            case .waiting(let error):
                Log.info("Connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        receiveLoop()
        startTimer()
        connection.start(queue: queue)
    }

    public func close(reason: String? = nil) {
        guard !isClosed else { return }
        if isAuthenticated, let reason {
            try? send(Message(seq: codec.nextSequence(), type: MessageType.bye, reason: reason))
        }
        connection.cancel()
    }

    /// Sends `bye` and only then drops the socket, waiting up to `timeout` for
    /// the frame to reach the network. That is what lets the phone hide its icon
    /// immediately instead of waiting for the heartbeat to time out.
    ///
    /// Must not be called from the session queue: the caller blocks while the
    /// queue does the work.
    public func closeGracefully(reason: String, timeout: TimeInterval = 1) {
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            guard !self.isClosed, self.isAuthenticated else {
                self.connection.cancel()
                finished.signal()
                return
            }
            do {
                let message = Message(seq: self.codec.nextSequence(), type: MessageType.bye, reason: reason)
                let body = try self.codec.seal(try message.encoded())
                Log.debug("-> bye (\(reason))")
                self.connection.send(content: Framing.frame(kind: .encrypted, body: body), completion: .contentProcessed { _ in
                    self.connection.cancel()
                    finished.signal()
                })
            } catch {
                self.connection.cancel()
                finished.signal()
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            Log.info("Goodbye frame did not flush in time, dropping the connection anyway")
            connection.cancel()
        }
    }

    private func finish(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        if let error {
            Log.info("Session with \(remoteDeviceName ?? remoteDescription) ended: \(error.localizedDescription)")
        } else {
            Log.info("Session with \(remoteDeviceName ?? remoteDescription) ended")
        }
        onEnd?(error)
    }

    // MARK: - Sending

    public func sendClipboard(text: String) throws {
        try send(Message(seq: codec.nextSequence(), type: MessageType.clipboard, text: text))
    }

    public func requestClipboard() throws {
        try send(Message(seq: codec.nextSequence(), type: MessageType.requestClipboard))
    }

    public func sendPing() throws {
        // Kept inside the signed 64 bit range so every JSON parser can read it.
        let token = UInt64.random(in: 1 ... UInt64(Int64.max))
        pendingPings[token] = Date()
        try send(Message(seq: codec.nextSequence(), type: MessageType.ping, token: token))
    }

    private func send(_ message: Message) throws {
        guard !isClosed else { return }
        let body = try codec.seal(try message.encoded())
        let frame = Framing.frame(kind: .encrypted, body: body)
        lastSend = Date()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error: error) }
        })
        Log.debug("-> \(message.type) seq=\(message.seq)")
    }

    private func sendChallenge() {
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        challenge = bytes

        let message = Message(
            type: MessageType.challenge,
            device: localDeviceName,
            deviceId: localDeviceId,
            challenge: bytes.base64EncodedString()
        )
        do {
            let frame = Framing.frame(kind: .plaintext, body: try message.encoded())
            lastSend = Date()
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(error: error) }
            })
            Log.debug("-> challenge")
        } catch {
            finish(error: error)
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Date()
                self.buffer.append(data)
                do {
                    try self.drainBuffer()
                } catch {
                    Log.error("Dropping connection: \(error.localizedDescription)")
                    self.finish(error: error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.finish(error: error)
                return
            }
            if isComplete {
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainBuffer() throws {
        while let frame = try Framing.nextFrame(from: &buffer) {
            switch frame.kind {
            case .plaintext:
                // The Mac is the server, so it is the only side allowed to send
                // a plaintext challenge.
                throw ProtocolError.unexpectedFrame("plaintext frame from the peer")
            case .encrypted:
                let message = try codec.open(frame.body)
                try handle(message)
            }
        }
    }

    private func handle(_ message: Message) throws {
        Log.debug("<- \(message.type) seq=\(message.seq)")

        guard isAuthenticated else {
            guard message.type == MessageType.hello else {
                throw ProtocolError.unexpectedFrame("expected hello, got \(message.type)")
            }
            guard let echoed = message.challenge,
                  let echoedData = Data(base64Encoded: echoed),
                  echoedData == challenge
            else {
                throw ProtocolError.unexpectedFrame("hello did not echo the challenge")
            }
            isAuthenticated = true
            remoteDeviceName = message.device ?? "Android device"
            try send(Message(
                seq: codec.nextSequence(),
                type: MessageType.helloAck,
                device: localDeviceName,
                deviceId: localDeviceId
            ))
            Log.info("Authenticated with \(remoteDeviceName!) (\(remoteDescription))")
            onAuthenticated?(remoteDeviceName!)
            return
        }

        switch message.type {
        case MessageType.clipboard:
            guard let text = message.text, !text.isEmpty else { return }
            try send(Message(seq: codec.nextSequence(), type: MessageType.clipboardAck))
            onClipboard?(text)
        case MessageType.clipboardAck:
            onClipboardAck?()
        case MessageType.requestClipboard:
            onClipboardRequested?()
        case MessageType.ping:
            try send(Message(seq: codec.nextSequence(), type: MessageType.pong, token: message.token))
        case MessageType.pong:
            guard let token = message.token, let sentAt = pendingPings.removeValue(forKey: token) else { return }
            onRoundTrip?(Date().timeIntervalSince(sentAt) * 1000)
        case MessageType.heartbeat:
            break
        case MessageType.bye:
            Log.info("Peer said goodbye: \(message.reason ?? "no reason")")
            connection.cancel()
        default:
            Log.info("Ignoring unknown message type \(message.type)")
        }
    }

    // MARK: - Liveness

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Sends a heartbeat while idle and drops the connection when the peer goes
    /// quiet, which is how the sync suspends itself once the phone is out of range.
    private func tick() {
        guard !isClosed else { return }
        let now = Date()
        if now.timeIntervalSince(lastReceive) > Wire.receiveTimeout {
            Log.info("No frame for \(Int(Wire.receiveTimeout))s, dropping the connection")
            connection.cancel()
            return
        }
        if isAuthenticated, now.timeIntervalSince(lastSend) >= Wire.heartbeatInterval {
            try? send(Message(seq: codec.nextSequence(), type: MessageType.heartbeat))
        }
        pendingPings = pendingPings.filter { now.timeIntervalSince($0.value) < 30 }
    }
}
