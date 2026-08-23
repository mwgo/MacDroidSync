import Foundation
import Network

/// Listens on the fixed port, advertises itself over Bonjour and keeps at most
/// one authenticated session with the phone. All callbacks are delivered on the
/// main queue so the menu bar can use them directly.
public final class SyncServer {
    public var onStateChange: ((PeerState) -> Void)?
    public var onClipboardReceived: ((String) -> Void)?
    public var onClipboardDelivered: (() -> Void)?
    public var onRoundTrip: ((Double) -> Void)?
    public var onFailure: ((String) -> Void)?
    /// Fired with the port once the listener is up and advertising itself.
    public var onListening: ((UInt16) -> Void)?
    /// Name, bytes received so far and the announced total of an incoming file.
    public var onFileProgress: ((String, Int64, Int64) -> Void)?
    /// A file arrived complete and is now sitting at this location.
    public var onFileReceived: ((URL, String) -> Void)?
    /// Name and reason of a file that did not make it.
    public var onFileFailed: ((String, String) -> Void)?
    /// Name, bytes sent so far and the total of a file going to the phone.
    public var onOutgoingProgress: ((String, Int64, Int64) -> Void)?
    /// The phone confirmed a file and told us where it saved it.
    public var onFileSent: ((String, String) -> Void)?
    /// Name and reason of a file the phone did not take.
    public var onFileSendFailed: ((String, String) -> Void)?

    public private(set) var state: PeerState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            let state = state
            DispatchQueue.main.async { self.onStateChange?(state) }
        }
    }

    public private(set) var connectedDeviceName: String?
    public private(set) var port: UInt16
    /// Where files coming from the phone are saved, `~/Downloads` by default.
    public let destinationDirectory: URL

    private let queue = DispatchQueue(label: "\(Log.subsystem).server")
    private let settings: SyncConfiguration
    private var listener: NWListener?
    private var session: PeerSession?
    private var isSuspended = false

    public init(
        settings: SyncConfiguration = Settings.shared,
        destinationDirectory: URL = FileReceiver.downloadsDirectory
    ) {
        self.settings = settings
        self.port = settings.port
        self.destinationDirectory = destinationDirectory
    }

    public var isConnected: Bool {
        queue.sync { session?.isAuthenticated == true }
    }

    // MARK: - Listener

    public func start() {
        queue.async { self.startLocked() }
    }

    public func stop() {
        queue.async {
            self.session?.close(reason: "macOS app is quitting")
            self.session = nil
            self.listener?.cancel()
            self.listener = nil
            self.state = .disconnected
        }
    }

    /// Stops serving until `resume()`: says goodbye to the phone, drops the
    /// session and stops advertising, so the phone hides its icon right away.
    /// Safe to call from the main thread while the system is going to sleep.
    public func suspend(reason: String) {
        let closing: PeerSession? = queue.sync {
            guard !isSuspended else { return nil }
            isSuspended = true
            let current = session
            session = nil
            connectedDeviceName = nil
            listener?.cancel()
            listener = nil
            state = .suspended
            Log.info("Sync suspended: \(reason)")
            return current
        }
        // Outside the queue on purpose: closeGracefully blocks the caller while
        // the session queue flushes the goodbye frame.
        closing?.closeGracefully(reason: reason)
    }

    public func resume() {
        queue.async {
            guard self.isSuspended else { return }
            self.isSuspended = false
            Log.info("Sync resumed")
            self.startLocked()
        }
    }

    /// Applies a new port or a new pairing code by rebuilding the listener and
    /// dropping the current session.
    public func restart() {
        queue.async {
            self.session?.close(reason: "settings changed")
            self.session = nil
            self.listener?.cancel()
            self.listener = nil
            self.startLocked()
        }
    }

    private func startLocked() {
        guard !isSuspended else { return }
        port = settings.port
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            report(failure: "Invalid port \(port)")
            return
        }

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            let name = settings.deviceName
            let txt = NWTXTRecord(["v": "1", "name": name, "id": settings.deviceId])
            listener.service = NWListener.Service(
                name: name,
                type: Wire.bonjourServiceType,
                domain: nil,
                txtRecord: txt
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Log.info("Listening on port \(self.port), advertising \(Wire.bonjourServiceType)")
                    if self.session == nil { self.state = .disconnected }
                    let port = self.port
                    DispatchQueue.main.async { self.onListening?(port) }
                case .failed(let error):
                    self.report(failure: "Listener failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            report(failure: "Could not listen on port \(port): \(error.localizedDescription)")
        }
    }

    private func report(failure message: String) {
        Log.error(message)
        state = .error
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        // A phone that lost Wi-Fi may leave a half open socket behind, so the
        // newest connection always wins.
        if let existing = session {
            Log.info("Replacing the existing session with \(existing.remoteDescription)")
            existing.close(reason: "replaced by a new connection")
            session = nil
        }

        let session = PeerSession(
            connection: connection,
            pairingCode: settings.pairingCode,
            localDeviceName: settings.deviceName,
            localDeviceId: settings.deviceId,
            queue: queue
        )
        self.session = session
        session.fileSink = FileReceiver(directory: destinationDirectory)
        state = .connecting

        session.onAuthenticated = { [weak self, weak session] deviceName in
            guard let self, let session, self.session === session else { return }
            self.connectedDeviceName = deviceName
            self.settings.pairedDeviceName = deviceName
            self.state = .connected
        }
        session.onClipboard = { [weak self] text in
            DispatchQueue.main.async { self?.onClipboardReceived?(text) }
        }
        session.onClipboardAck = { [weak self] in
            DispatchQueue.main.async { self?.onClipboardDelivered?() }
        }
        session.onRoundTrip = { [weak self] milliseconds in
            DispatchQueue.main.async { self?.onRoundTrip?(milliseconds) }
        }
        session.onFileProgress = { [weak self] name, received, total in
            DispatchQueue.main.async { self?.onFileProgress?(name, received, total) }
        }
        session.onFileReceived = { [weak self] url, name in
            DispatchQueue.main.async { self?.onFileReceived?(url, name) }
        }
        session.onFileFailed = { [weak self] name, reason in
            DispatchQueue.main.async { self?.onFileFailed?(name, reason) }
        }
        session.onOutgoingProgress = { [weak self] name, sent, total in
            DispatchQueue.main.async { self?.onOutgoingProgress?(name, sent, total) }
        }
        session.onFileSent = { [weak self] name, path in
            DispatchQueue.main.async { self?.onFileSent?(name, path) }
        }
        session.onFileSendFailed = { [weak self] name, reason in
            DispatchQueue.main.async { self?.onFileSendFailed?(name, reason) }
        }
        session.onEnd = { [weak self, weak session] _ in
            guard let self, self.session === session else { return }
            self.session = nil
            self.connectedDeviceName = nil
            self.state = self.isSuspended ? .suspended : .disconnected
        }
        session.start()
    }

    // MARK: - Outgoing

    /// Returns false when there is nobody to send to, which tells the caller to
    /// keep the value in the offline queue.
    @discardableResult
    public func sendClipboard(text: String) -> Bool {
        queue.sync {
            guard let session, session.isAuthenticated else { return false }
            do {
                try session.sendClipboard(text: text)
                return true
            } catch {
                Log.error("Could not send the clipboard: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// True when the file is on its way. A failure to even start (no phone, file
    /// gone, over the size limit) comes back as the thrown reason so the caller
    /// can show it and decide whether to keep the item queued.
    public func sendFile(url: URL) throws -> Bool {
        try queue.sync {
            guard let session, session.isAuthenticated else { return false }
            guard !session.isSendingFile else { return false }
            try session.startSendingFile(url: url)
            return true
        }
    }

    /// Whether a transfer to the phone is currently in flight.
    public var isSendingFile: Bool {
        queue.sync { session?.isSendingFile == true }
    }

    @discardableResult
    public func ping() -> Bool {
        queue.sync {
            guard let session, session.isAuthenticated else { return false }
            do {
                try session.sendPing()
                return true
            } catch {
                Log.error("Could not send the ping: \(error.localizedDescription)")
                return false
            }
        }
    }
}
