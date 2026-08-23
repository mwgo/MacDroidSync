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
    /// Name, bytes received so far and the announced total of the file in flight.
    public var onFileProgress: ((String, Int64, Int64) -> Void)?
    /// Final location and name of a file that arrived complete.
    public var onFileReceived: ((URL, String) -> Void)?
    /// Name and reason of a file that did not make it.
    public var onFileFailed: ((String, String) -> Void)?
    /// Name, bytes sent so far and the total of the file going to the phone.
    public var onOutgoingProgress: ((String, Int64, Int64) -> Void)?
    /// Name of a file the phone confirmed, plus where it saved it.
    public var onFileSent: ((String, String) -> Void)?
    /// Name and reason of a file the phone did not take.
    public var onFileSendFailed: ((String, String) -> Void)?
    /// Whether the phone is broadcasting its presence beacon. Reported from
    /// `hello` and again whenever the switch on the phone is flipped, because
    /// otherwise the Mac could not tell "the user turned the feature off" apart
    /// from "the user walked away".
    public var onPresencePreference: ((Bool) -> Void)?
    /// The phone asked for this Mac to be locked right now. Deliberately not
    /// tied to the auto lock: locking is the safe direction, and the button on
    /// the phone has to work whether or not the automatic feature is on.
    public var onLockRequested: (() -> Void)?

    /// Where incoming files are written; without a sink they are refused.
    public var fileSink: FileSink?

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
    private var incomingFile: FileOffer?
    private var lastProgressReport = Date.distantPast
    private var outgoing: FileSender?
    private var chunksInFlight = 0
    private var lastOutgoingReport = Date.distantPast
    /// When `file-end` went out, so a phone that never answers cannot stall the queue.
    private var awaitingAckSince: Date?

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
        if let interrupted = incomingFile {
            incomingFile = nil
            fileSink?.abort()
            onFileFailed?(interrupted.name, "the connection dropped mid transfer")
        }
        if let sending = outgoing {
            outgoing = nil
            awaitingAckSince = nil
            sending.cancel()
            onFileSendFailed?(sending.name, "the connection dropped mid transfer")
        }
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

    /// `whenProcessed` fires once the frame has actually been handed to the
    /// network, which is what paces the outgoing file pump.
    private func send(_ message: Message, whenProcessed: (() -> Void)? = nil) throws {
        guard !isClosed else { return }
        let body = try codec.seal(try message.encoded())
        let frame = Framing.frame(kind: .encrypted, body: body)
        lastSend = Date()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error: error)
                return
            }
            whenProcessed?()
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
            if let beacon = message.beacon {
                Log.info("Phone says its presence beacon is \(beacon ? "on" : "off")")
                onPresencePreference?(beacon)
            }
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
        case MessageType.fileOffer:
            try handleFileOffer(message)
        case MessageType.fileChunk:
            try handleFileChunk(message)
        case MessageType.fileEnd:
            try handleFileEnd(message)
        case MessageType.fileAck:
            handleFileAck(message)
        case MessageType.presence:
            guard let beacon = message.beacon else { return }
            Log.info("Phone turned its presence beacon \(beacon ? "on" : "off")")
            onPresencePreference?(beacon)
        case MessageType.lock:
            Log.info("Phone asked to lock the screen")
            onLockRequested?()
        case MessageType.bye:
            Log.info("Peer said goodbye: \(message.reason ?? "no reason")")
            connection.cancel()
        default:
            Log.info("Ignoring unknown message type \(message.type)")
        }
    }

    // MARK: - Outgoing files

    public var isSendingFile: Bool { outgoing != nil }

    /// Starts streaming `url` to the phone. Must be called on the session queue.
    /// Throws when the file cannot be sent at all; a phone side refusal arrives
    /// later through `onFileSendFailed`.
    public func startSendingFile(url: URL) throws {
        guard isAuthenticated, !isClosed else { throw FileTransferError.refusedByPeer("no phone connected") }
        guard outgoing == nil else { throw FileTransferError.refusedByPeer("another file is still going out") }

        let sender = try FileSender(url: url)
        outgoing = sender
        chunksInFlight = 0
        lastOutgoingReport = .distantPast
        awaitingAckSince = nil
        Log.info("Sending \(sender.name) (\(ByteCountFormatter.string(fromByteCount: sender.size, countStyle: .file)))")
        do {
            try send(Message(
                seq: codec.nextSequence(),
                type: MessageType.fileOffer,
                fileId: sender.id,
                name: sender.name,
                size: sender.size,
                mime: sender.mime
            ))
        } catch {
            outgoing = nil
            sender.cancel()
            throw error
        }
        reportOutgoingProgress(force: true)
        pumpChunks()
    }

    /// Keeps up to `Wire.fileSendWindow` chunks in flight: enough to stop waiting
    /// for a full round trip per chunk, few enough that memory stays bounded no
    /// matter how large the file is. The connection preserves order, so `file-end`
    /// can be queued right behind the last chunk.
    private func pumpChunks() {
        guard let sender = outgoing, !sender.isCancelled, !isClosed else { return }
        // The last chunk's completion calls back in here after `file-end` has
        // already gone out; without this the frame would be sent twice.
        guard awaitingAckSince == nil else { return }
        while chunksInFlight < Wire.fileSendWindow {
            do {
                guard let chunk = try sender.nextChunk() else {
                    try send(Message(
                        seq: codec.nextSequence(),
                        type: MessageType.fileEnd,
                        fileId: sender.id,
                        sha256: sender.checksum()
                    ))
                    sender.close()
                    awaitingAckSince = Date()
                    return
                }
                chunksInFlight += 1
                try send(
                    Message(
                        seq: codec.nextSequence(),
                        type: MessageType.fileChunk,
                        fileId: sender.id,
                        data: chunk.base64EncodedString()
                    ),
                    whenProcessed: { [weak self] in
                        guard let self else { return }
                        self.chunksInFlight -= 1
                        self.reportOutgoingProgress()
                        self.pumpChunks()
                    }
                )
            } catch {
                failOutgoing(reason: error.localizedDescription)
                return
            }
        }
    }

    private func handleFileAck(_ message: Message) {
        guard let sender = outgoing, message.fileId == nil || message.fileId == sender.id else {
            Log.info("Ignoring a file-ack that belongs to no transfer of ours")
            return
        }
        outgoing = nil
        awaitingAckSince = nil
        sender.cancel()

        if message.ok == true {
            let path = message.path ?? ""
            Log.info("The phone saved \(sender.name)\(path.isEmpty ? "" : " as \(path)")")
            onFileSent?(sender.name, path)
        } else {
            let reason = message.reason ?? "the phone refused the file"
            Log.error("The phone refused \(sender.name): \(reason)")
            onFileSendFailed?(sender.name, reason)
        }
    }

    private func failOutgoing(reason: String) {
        guard let sender = outgoing else { return }
        outgoing = nil
        awaitingAckSince = nil
        sender.cancel()
        Log.error("Sending \(sender.name) failed: \(reason)")
        onFileSendFailed?(sender.name, reason)
    }

    private func reportOutgoingProgress(force: Bool = false) {
        guard let sender = outgoing else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastOutgoingReport) >= 0.2 else { return }
        lastOutgoingReport = now
        onOutgoingProgress?(sender.name, sender.sentBytes, sender.size)
    }

    // MARK: - Incoming files

    private func handleFileOffer(_ message: Message) throws {
        let offer = FileOffer(
            id: message.fileId ?? UUID().uuidString,
            name: message.name ?? "file",
            size: message.size ?? 0,
            mime: message.mime
        )
        guard let sink = fileSink else {
            try rejectFile(offer, reason: "this Mac has nowhere to save files")
            return
        }
        do {
            try sink.begin(offer)
            incomingFile = offer
            lastProgressReport = .distantPast
            reportProgress(force: true)
        } catch {
            try rejectFile(offer, reason: error.localizedDescription)
        }
    }

    private func handleFileChunk(_ message: Message) throws {
        guard let offer = incomingFile, let sink = fileSink else {
            Log.info("Ignoring a file-chunk arriving outside a transfer")
            return
        }
        guard let encoded = message.data, let chunk = Data(base64Encoded: encoded) else {
            incomingFile = nil
            sink.abort()
            try rejectFile(offer, reason: "malformed chunk")
            return
        }
        do {
            try sink.append(chunk)
            reportProgress()
        } catch {
            incomingFile = nil
            try rejectFile(offer, reason: error.localizedDescription)
        }
    }

    private func handleFileEnd(_ message: Message) throws {
        guard let offer = incomingFile, let sink = fileSink else {
            Log.info("Ignoring a file-end arriving outside a transfer")
            return
        }
        incomingFile = nil
        do {
            let url = try sink.finish(sha256: message.sha256)
            try send(Message(
                seq: codec.nextSequence(),
                type: MessageType.fileAck,
                fileId: offer.id,
                name: offer.name,
                ok: true,
                path: url.path
            ))
            onFileReceived?(url, offer.name)
        } catch {
            try rejectFile(offer, reason: error.localizedDescription)
        }
    }

    /// Tells the phone the transfer is off, which also stops it from sending the
    /// remaining chunks.
    private func rejectFile(_ offer: FileOffer, reason: String) throws {
        Log.error("Refused \(offer.name): \(reason)")
        try send(Message(
            seq: codec.nextSequence(),
            type: MessageType.fileAck,
            reason: reason,
            fileId: offer.id,
            name: offer.name,
            ok: false
        ))
        onFileFailed?(offer.name, reason)
    }

    /// Throttled so a fast transfer does not flood the menu with redraws.
    private func reportProgress(force: Bool = false) {
        guard let offer = incomingFile, let sink = fileSink else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressReport) >= 0.2 else { return }
        lastProgressReport = now
        onFileProgress?(offer.name, sink.receivedBytes, offer.size)
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
        if let since = awaitingAckSince, now.timeIntervalSince(since) > Wire.fileAckTimeout {
            failOutgoing(reason: "the phone never confirmed the transfer")
        }
        pendingPings = pendingPings.filter { now.timeIntervalSince($0.value) < 30 }
    }
}
