import AppKit
import MacDroidSyncCore

/// Owns the status item, its menu and the wiring between the pasteboard, the
/// server and the offline queue.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let settings = Settings.shared
    private let server = SyncServer()
    private let watcher = PasteboardWatcher()
    private let pending = PendingStore()
    private let power = PowerMonitor()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pingMenuItem = NSMenuItem(title: "Ping phone", action: #selector(pingPhone), keyEquivalent: "p")
    private let sendMenuItem = NSMenuItem(title: "Send clipboard now", action: #selector(sendClipboardNow), keyEquivalent: "s")
    private let lastSentMenuItem = NSMenuItem(title: "Nothing sent yet", action: nil, keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var displayState: PeerState = .disconnected
    private var failureMessage: String?
    private var suspendReason: String?
    private var lastSentSummary: String?
    private var pingResetWorkItem: DispatchWorkItem?
    private var flashWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        buildMenu()
        wireServer()
        wireWatcher()
        wirePower()
        render(state: .disconnected)

        server.start()
        watcher.start()
        power.start()
    }

    func shutDown() {
        power.stop()
        watcher.stop()
        server.stop()
    }

    // MARK: - Menu

    private func buildMenu() {
        statusMenuItem.isEnabled = false
        lastSentMenuItem.isEnabled = false

        for item in [pingMenuItem, sendMenuItem, launchAtLoginMenuItem] {
            item.target = self
        }

        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(pingMenuItem)
        menu.addItem(sendMenuItem)
        menu.addItem(lastSentMenuItem)
        menu.addItem(.separator())

        let pairingItem = NSMenuItem(title: "Pairing code…", action: #selector(showPairingCode), keyEquivalent: "")
        pairingItem.target = self
        menu.addItem(pairingItem)

        let portItem = NSMenuItem(title: "Port…", action: #selector(changePort), keyEquivalent: "")
        portItem.target = self
        menu.addItem(portItem)

        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MacDroidSync", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        switch displayState {
        case .connected, .transferring:
            statusMenuItem.title = "Connected: \(server.connectedDeviceName ?? "Android device")"
        case .connecting:
            statusMenuItem.title = "Connecting…"
        case .disconnected:
            statusMenuItem.title = "Listening on port \(settings.port)"
        case .suspended:
            statusMenuItem.title = "Suspended, \(suspendReason ?? "the Mac is away")"
        case .error:
            statusMenuItem.title = failureMessage ?? "Error"
        }

        let connected = displayState == .connected || displayState == .transferring
        pingMenuItem.isEnabled = connected
        sendMenuItem.isEnabled = connected || pending.pending == nil

        if let summary = lastSentSummary {
            lastSentMenuItem.title = summary
        } else if let queued = pending.pending {
            lastSentMenuItem.title = "Queued: \(Self.summarize(queued.text))"
        } else {
            lastSentMenuItem.title = "Nothing sent yet"
        }

        launchAtLoginMenuItem.state = settings.launchAtLoginEnabled ? .on : .off
    }

    private func render(state: PeerState) {
        displayState = state
        statusItem.button?.image = StatusIcon.image(for: state)
        statusItem.button?.alphaValue = StatusIcon.alpha(for: state)
        statusItem.button?.toolTip = StatusIcon.accessibilityDescription(for: state)
        refreshMenuTitles()
    }

    /// Brief icon flash whenever a clipboard actually moves.
    private func flashTransfer() {
        guard server.isConnected else { return }
        flashWorkItem?.cancel()
        render(state: .transferring)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.render(state: self.server.isConnected ? .connected : .disconnected)
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Wiring

    private func wireServer() {
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.failureMessage = state == .error ? self.failureMessage : nil
            self.render(state: state)
            if state == .connected { self.flushPending() }
        }
        server.onClipboardReceived = { [weak self] text in
            guard let self else { return }
            self.watcher.apply(remoteText: text)
            self.lastSentSummary = "Received: \(Self.summarize(text))"
            self.flashTransfer()
        }
        server.onClipboardDelivered = { [weak self] in
            self?.pending.clear()
            self?.refreshMenuTitles()
        }
        server.onRoundTrip = { [weak self] milliseconds in
            self?.showPingResult(milliseconds: milliseconds)
        }
        server.onListening = { [weak self] _ in
            self?.failureMessage = nil
            self?.refreshMenuTitles()
        }
        server.onFailure = { [weak self] message in
            guard let self else { return }
            self.failureMessage = message
            self.render(state: .error)
        }
    }

    /// Closing the lid or going to sleep stops the sync on purpose, so the phone
    /// hides its status bar icon instead of waiting for the connection to time out.
    private func wirePower() {
        power.onSuspend = { [weak self] reason in
            guard let self else { return }
            self.suspendReason = reason.rawValue
            self.server.suspend(reason: reason.rawValue)
            self.render(state: .suspended)
        }
        power.onResume = { [weak self] in
            guard let self else { return }
            self.suspendReason = nil
            self.render(state: .disconnected)
            self.server.resume()
        }
    }

    private func wireWatcher() {
        watcher.onCopy = { [weak self] text in
            self?.deliver(text: text)
        }
    }

    private func deliver(text: String) {
        if server.sendClipboard(text: text) {
            pending.store(text: text)   // cleared once the phone acknowledges it
            lastSentSummary = "Sent: \(Self.summarize(text))"
            flashTransfer()
        } else {
            pending.store(text: text)
            lastSentSummary = nil
            Log.info("Phone unavailable, clipboard queued for the next connection")
        }
        refreshMenuTitles()
    }

    private func flushPending() {
        guard let item = pending.pending else { return }
        Log.info("Flushing the queued clipboard from \(Date(timeIntervalSince1970: Double(item.ts) / 1000))")
        if server.sendClipboard(text: item.text) {
            lastSentSummary = "Sent: \(Self.summarize(item.text))"
            flashTransfer()
            refreshMenuTitles()
        }
    }

    // MARK: - Actions

    @objc private func pingPhone() {
        guard server.ping() else {
            showAlert(title: "No phone connected", message: unavailableExplanation)
            return
        }
        pingMenuItem.title = "Pinging…"
    }

    private var unavailableExplanation: String {
        if displayState == .suspended {
            return "The sync is suspended because \(suspendReason ?? "the Mac is away"). Open the lid to resume."
        }
        return "MacDroidSync is still waiting for the Android app to connect."
    }

    private func showPingResult(milliseconds: Double) {
        pingResetWorkItem?.cancel()
        pingMenuItem.title = String(format: "Ping: %.0f ms", milliseconds)
        let work = DispatchWorkItem { [weak self] in self?.pingMenuItem.title = "Ping phone" }
        pingResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @objc private func sendClipboardNow() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showAlert(title: "Clipboard is empty", message: "There is no text on the clipboard to send.")
            return
        }
        watcher.suppress(text: text)
        deliver(text: text)
    }

    @objc private func showPairingCode() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Pairing code"
        alert.informativeText = """
            Enter this code in the Android app:

            \(settings.pairingCode)

            The code is the shared secret used to encrypt every clipboard transfer.
            """
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Close")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let code = settings.pairingCode
            watcher.suppress(text: code)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        case .alertSecondButtonReturn:
            let code = settings.regeneratePairingCode()
            server.restart()
            showAlert(title: "New pairing code", message: "\(code)\n\nEnter it in the Android app to reconnect.")
        default:
            break
        }
    }

    @objc private func changePort() {
        NSApp.activate()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(settings.port)

        let alert = NSAlert()
        alert.messageText = "Listening port"
        alert.informativeText = "Both apps must use the same port. Default is \(Wire.defaultPort)."
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), value >= 1024 else {
            showAlert(title: "Invalid port", message: "Use a number between 1024 and 65535.")
            return
        }
        settings.port = value
        server.restart()
        refreshMenuTitles()
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !settings.launchAtLoginEnabled
        do {
            try settings.setLaunchAtLogin(enable)
        } catch {
            showAlert(
                title: "Could not update the login item",
                message: "\(error.localizedDescription)\n\nMove MacDroidSync.app to /Applications and try again."
            )
        }
        refreshMenuTitles()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func summarize(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count <= 40 ? flattened : String(flattened.prefix(40)) + "…"
    }
}
