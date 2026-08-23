import AppKit
import MacDroidSyncCore

/// Owns the status item, its menu and the wiring between the pasteboard, the
/// server and the offline queue.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let settings = Settings.shared
    private let server = SyncServer()
    private let watcher = PasteboardWatcher()
    private let pending = PendingStore()
    private let outbox = OutboxStore()
    private let power = PowerMonitor()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pingMenuItem = NSMenuItem(title: "Ping phone", action: #selector(pingPhone), keyEquivalent: "p")
    private let sendMenuItem = NSMenuItem(title: "Send clipboard now", action: #selector(sendClipboardNow), keyEquivalent: "s")
    private let lastSentMenuItem = NSMenuItem(title: "Nothing sent yet", action: nil, keyEquivalent: "")
    private let sendFilesMenuItem = NSMenuItem(title: "Send files to phone…", action: #selector(sendFiles), keyEquivalent: "o")
    private let outgoingMenuItem = NSMenuItem(title: "No files sent yet", action: nil, keyEquivalent: "")
    private let fileMenuItem = NSMenuItem(title: "No files received yet", action: #selector(revealLastFile), keyEquivalent: "")
    private let downloadsMenuItem = NSMenuItem(title: "Open Downloads folder", action: #selector(openDownloads), keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private let notifier = Notifier()
    private lazy var serviceProvider = ServiceProvider { [weak self] urls in
        self?.enqueue(files: urls)
    }

    private var displayState: PeerState = .disconnected
    private var failureMessage: String?
    private var suspendReason: String?
    private var lastSentSummary: String?
    private var fileStatus: String?
    private var lastReceivedFile: URL?
    private var outgoingStatus: String?
    /// Queue entry currently in flight, so its ack can clear the right item.
    private var sendingItemId: String?
    private var sendAttempts: [String: Int] = [:]
    private var shareWatcher: DispatchSourceFileSystemObject?
    private var pingResetWorkItem: DispatchWorkItem?
    private var flashWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        buildMenu()
        wireServer()
        wireWatcher()
        wirePower()
        wireServices()
        wireShareInbox()
        render(state: .disconnected)

        server.start()
        watcher.start()
        power.start()
        notifier.requestAuthorization()
    }

    func shutDown() {
        shareWatcher?.cancel()
        shareWatcher = nil
        power.stop()
        watcher.stop()
        server.stop()
    }

    // MARK: - Menu

    private func buildMenu() {
        statusMenuItem.isEnabled = false
        lastSentMenuItem.isEnabled = false

        outgoingMenuItem.isEnabled = false

        for item in [pingMenuItem, sendMenuItem, sendFilesMenuItem, fileMenuItem, downloadsMenuItem, launchAtLoginMenuItem] {
            item.target = self
        }

        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(pingMenuItem)
        menu.addItem(sendMenuItem)
        menu.addItem(lastSentMenuItem)
        menu.addItem(.separator())
        menu.addItem(sendFilesMenuItem)
        menu.addItem(outgoingMenuItem)
        menu.addItem(fileMenuItem)
        menu.addItem(downloadsMenuItem)
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

        sendFilesMenuItem.isEnabled = true
        outgoingMenuItem.title = outgoingSummary

        fileMenuItem.title = fileStatus ?? "No files received yet"
        // Only clickable once there is a file to point Finder at.
        fileMenuItem.isEnabled = lastReceivedFile != nil
        downloadsMenuItem.title = "Open \(server.destinationDirectory.lastPathComponent) folder"

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
            if state == .connected {
                self.flushPending()
                self.drainOutbox()
            }
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
        server.onFileProgress = { [weak self] name, received, total in
            guard let self else { return }
            self.fileStatus = Self.progressSummary(name: name, done: received, total: total)
            // Progress arrives at least every 200 ms, so the icon stays lit for
            // the whole transfer.
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onFileReceived = { [weak self] url, _ in
            guard let self else { return }
            self.lastReceivedFile = url
            self.fileStatus = "Received: \(url.lastPathComponent)"
            self.fileMenuItem.toolTip = url.path
            self.notifier.fileReceived(at: url, from: self.server.connectedDeviceName ?? "your phone")
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onFileFailed = { [weak self] name, reason in
            guard let self else { return }
            self.fileStatus = "Failed: \(name)"
            self.fileMenuItem.toolTip = reason
            self.notifier.fileFailed(name: name, reason: reason)
            self.refreshMenuTitles()
        }
        server.onOutgoingProgress = { [weak self] name, sent, total in
            guard let self else { return }
            self.outgoingStatus = Self.progressSummary(verb: "Sending", name: name, done: sent, total: total)
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onFileSent = { [weak self] name, path in
            guard let self else { return }
            if let id = self.sendingItemId {
                self.outbox.remove(id: id)
                self.sendAttempts[id] = nil
                self.sendingItemId = nil
            }
            self.outgoingStatus = "Sent: \(name)"
            Log.info("\(name) reached the phone\(path.isEmpty ? "" : " (\(path))")")
            self.flashTransfer()
            self.refreshMenuTitles()
            self.drainOutbox()
        }
        server.onFileSendFailed = { [weak self] name, reason in
            self?.handleSendFailure(name: name, reason: reason)
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

    /// Registers the `Send to Android` entry declared under NSServices.
    private func wireServices() {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// Picks up whatever the Share extension dropped, both at startup and while
    /// the app is running.
    private func wireShareInbox() {
        ingestShareRequests()
        shareWatcher = ShareInbox.watch(queue: .main) { [weak self] in
            self?.ingestShareRequests()
        }
    }

    private func ingestShareRequests() {
        let urls = ShareInbox.takeAll()
        guard !urls.isEmpty else { return }
        Log.info("Picked up \(urls.count) shared file(s)")
        enqueue(files: urls)
    }

    // MARK: - Files to the phone

    /// Queues files and starts sending right away when the phone is around.
    func enqueue(files: [URL]) {
        guard !files.isEmpty else { return }
        outbox.enqueue(files)
        refreshMenuTitles()
        drainOutbox()
    }

    /// Sends the head of the queue, one file at a time.
    private func drainOutbox() {
        guard server.isConnected, !server.isSendingFile, sendingItemId == nil else { return }
        guard let item = outbox.first(onMissing: { [weak self] missing in
            guard let self else { return }
            self.outgoingStatus = "Missing: \(missing.name)"
            self.notifier.fileFailed(name: missing.name, reason: "the file is no longer there")
        }) else {
            refreshMenuTitles()
            return
        }

        do {
            if try server.sendFile(url: item.url) {
                sendingItemId = item.id
                outgoingStatus = "Sending \(item.name)…"
                flashTransfer()
            }
        } catch {
            // Nothing about this file can ever work: drop it and move on.
            outbox.remove(id: item.id)
            outgoingStatus = "Failed: \(item.name)"
            Log.error("Cannot send \(item.name): \(error.localizedDescription)")
            notifier.fileFailed(name: item.name, reason: error.localizedDescription)
            refreshMenuTitles()
            drainOutbox()
            return
        }
        refreshMenuTitles()
    }

    /// A failure is only final after a few tries: a dropped connection has to
    /// leave the file in the queue for the next one.
    private func handleSendFailure(name: String, reason: String) {
        let id = sendingItemId
        sendingItemId = nil

        if let id {
            let tries = (sendAttempts[id] ?? 0) + 1
            sendAttempts[id] = tries
            if tries >= Self.maxSendAttempts {
                outbox.remove(id: id)
                sendAttempts[id] = nil
                outgoingStatus = "Failed: \(name)"
                notifier.fileFailed(name: name, reason: reason)
            } else {
                outgoingStatus = "Retrying \(name) later"
            }
        } else {
            outgoingStatus = "Failed: \(name)"
        }
        Log.error("Sending \(name) failed: \(reason)")
        refreshMenuTitles()
        drainOutbox()
    }

    private var outgoingSummary: String {
        if let outgoingStatus { return outgoingStatus }
        let queued = outbox.count
        if queued > 0 { return "Queued: \(queued) file\(queued == 1 ? "" : "s")" }
        return "No files sent yet"
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

    @objc private func sendFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Send files to the phone"
        panel.message = "The files are saved in the Downloads folder on the phone."
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if !server.isConnected {
            outgoingStatus = nil
            Log.info("No phone connected, \(panel.urls.count) file(s) queued")
        }
        enqueue(files: panel.urls)
    }

    @objc private func revealLastFile() {
        guard let url = lastReceivedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openDownloads() {
        NSWorkspace.shared.open(server.destinationDirectory)
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

    /// "Receiving photo.jpg - 45%", or plain bytes while the size is unknown.
    private static func progressSummary(verb: String = "Receiving", name: String, done: Int64, total: Int64) -> String {
        let readable = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        guard total > 0 else { return "\(verb) \(name) - \(readable)" }
        let percent = Int((Double(done) / Double(total) * 100).rounded(.down))
        return "\(verb) \(name) - \(min(percent, 100))%"
    }

    private static let maxSendAttempts = 3

    private static func summarize(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count <= 40 ? flattened : String(flattened.prefix(40)) + "…"
    }
}
