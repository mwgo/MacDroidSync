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
    private let presence = PresenceScanner()
    private let safeNetworks = SafeNetworkStore()
    private let network = NetworkMonitor()
    private let photoIndex = PhotoIndexStore()
    private lazy var photoImporter = PhotoImporter(
        library: PhotoKitLibrary(),
        index: photoIndex,
        readAlbumIdentifier: { Settings.shared.photosAlbumIdentifier },
        writeAlbumIdentifier: { Settings.shared.photosAlbumIdentifier = $0 }
    )
    private lazy var photoSync = PhotoSyncCoordinator(importer: photoImporter) { [weak self] keys, id in
        self?.server.requestPhotos(keys: keys, manifestId: id)
    }
    private var photoReport = PhotoSyncReport()
    /// The photo in flight, shown on the photo line while it arrives.
    private var photoTransfer: String?

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
    private let autoLockMenuItem = NSMenuItem(title: "Lock when the phone leaves", action: #selector(toggleAutoLock), keyEquivalent: "")
    private let presenceMenuItem = NSMenuItem(title: "Auto lock is off", action: nil, keyEquivalent: "")
    private let snoozeMenuItem = NSMenuItem(title: "Pause auto lock for an hour", action: #selector(toggleSnooze), keyEquivalent: "")
    private let photoStatusMenuItem = NSMenuItem(title: "Photo sync is off", action: nil, keyEquivalent: "")
    private let photoApproveMenuItem = NSMenuItem(title: "Import photos…", action: #selector(approvePhotos), keyEquivalent: "")
    private let photoRemoveMenuItem = NSMenuItem(title: "Remove photos from Photos…", action: #selector(removePhotos), keyEquivalent: "")
    private let photoSyncNowMenuItem = NSMenuItem(title: "Sync photos now", action: #selector(syncPhotosNow), keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
    private let quitMenuItem = NSMenuItem(title: "Quit MacDroidSync", action: #selector(quit), keyEquivalent: "q")

    private let notifier = Notifier()
    private let countdown = LockCountdownWindow()
    /// Built on first use: the window is the exception in a menu bar app, not
    /// something every session needs.
    private var settingsWindow: SettingsWindowController?
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
    /// The phone can switch its beacon off; until it says otherwise we assume it
    /// is on, because that is what an older phone build does too.
    private var phoneAllowsBeacon = true
    private var isScreenLocked = false
    private var lockStateObservers: [NSObjectProtocol] = []
    private var snoozeWorkItem: DispatchWorkItem?
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
        wirePresence()
        wirePhotos()
        render(state: .disconnected)

        server.start()
        watcher.start()
        power.start()
        network.start()
        notifier.requestAuthorization()

        // Says in the log where the auto lock stands before anything else has
        // happened. Without it the first word on the subject waits for the
        // keychain read below, and a feature that is quietly standing down - on
        // a safe network, say - looks the same as one that is working.
        updatePresenceScanning()

        // Deliberately off the main thread: the scanner needs the pairing code,
        // and the very first keychain read can take a dozen seconds, which would
        // otherwise freeze the menu bar for exactly that long.
        DispatchQueue.global(qos: .utility).async {
            _ = Settings.shared.pairingCode
            DispatchQueue.main.async { self.updatePresenceScanning() }
        }
    }

    func shutDown() {
        shareWatcher?.cancel()
        shareWatcher = nil
        snoozeWorkItem?.cancel()
        countdown.hide()
        settingsWindow?.close()
        lockStateObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        lockStateObservers.removeAll()
        presence.stop()
        network.stop()
        power.stop()
        watcher.stop()
        server.stop()
    }

    // MARK: - Menu

    private func buildMenu() {
        statusMenuItem.isEnabled = false
        lastSentMenuItem.isEnabled = false
        outgoingMenuItem.isEnabled = false
        presenceMenuItem.isEnabled = false

        for item in [
            pingMenuItem, sendMenuItem, sendFilesMenuItem, fileMenuItem, downloadsMenuItem,
            autoLockMenuItem, snoozeMenuItem, settingsMenuItem, quitMenuItem,
            photoApproveMenuItem, photoRemoveMenuItem, photoSyncNowMenuItem,
        ] {
            item.target = self
        }
        photoStatusMenuItem.isEnabled = false

        // What the menu carries is state and the handful of things worth doing
        // from the menu bar. Everything that is set once and then left alone
        // lives in the settings window instead.
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
        menu.addItem(autoLockMenuItem)
        menu.addItem(presenceMenuItem)
        menu.addItem(snoozeMenuItem)
        menu.addItem(.separator())
        // In order of what needs a decision: the state, then the two things only
        // the operator may set off, then the manual run.
        menu.addItem(photoStatusMenuItem)
        menu.addItem(photoApproveMenuItem)
        menu.addItem(photoRemoveMenuItem)
        menu.addItem(photoSyncNowMenuItem)
        menu.addItem(.separator())
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)

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

        photoStatusMenuItem.title = photoSummary ?? "Photo sync is off"
        // The two destructive-or-committing actions only appear as available when
        // there is really something to decide about.
        photoApproveMenuItem.isHidden = photoReport.awaitingApproval == 0
        photoApproveMenuItem.title = "Import \(photoReport.awaitingApproval) photos "
            + "(\(Self.bytes(photoReport.awaitingBytes)))…"
        photoRemoveMenuItem.isHidden = photoReport.pendingDeletions == 0
        photoRemoveMenuItem.title = "Remove \(photoReport.pendingDeletions) photos from Photos…"
        photoSyncNowMenuItem.isEnabled = connected && settings.photosEnabled

        fileMenuItem.title = fileStatus ?? "No files received yet"
        // Only clickable once there is a file to point Finder at.
        fileMenuItem.isEnabled = lastReceivedFile != nil
        downloadsMenuItem.title = "Open \(server.destinationDirectory.lastPathComponent) folder"

        let autoLock = settings.autoLockEnabled
        autoLockMenuItem.state = autoLock ? .on : .off
        presenceMenuItem.title = autoLockSummary
        presenceMenuItem.toolTip = presence.state == .unarmed && autoLock
            ? "The screen is never locked until the phone has been seen at least once."
            : nil
        snoozeMenuItem.isEnabled = autoLock
        snoozeMenuItem.title = settings.autoLockSnoozeUntil == nil
            ? "Pause auto lock for an hour"
            : "Resume auto lock"

        // The window shows the same settings from the other side, so it is
        // refreshed from the one place that already knows they changed.
        settingsWindow?.refresh()
    }

    /// The live reading is the only practical way to calibrate the threshold:
    /// walk away and watch what it says. The settings window shows the same line
    /// next to the threshold field, which is where the calibrating happens.
    private var autoLockSummary: String {
        guard settings.autoLockEnabled else { return "Auto lock is off" }
        if let until = settings.autoLockSnoozeUntil {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Paused until \(formatter.string(from: until))"
        }
        if !phoneAllowsBeacon { return "The phone has the beacon switched off" }
        if isScreenLocked { return "Screen is locked" }
        if let safe = safeNetworkName { return "Safe network: \(safe)" }
        guard presence.availability == .scanning else { return presence.availability.rawValue.capitalizedFirst }
        guard let mean = presence.meanRSSI else {
            if let seconds = presence.secondsSinceLastBeacon {
                return String(format: "Phone: heard %.0f s ago", seconds)
            }
            return "Phone: not seen yet"
        }
        let state: String
        switch presence.state {
        case .unarmed: state = "waiting"
        case .near: state = "near"
        case .leaving: state = "leaving"
        }
        return String(format: "Phone: %.0f dBm (%@)", mean, state)
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
            // A sleeping Mac with a closed lid needs no locking, and the beacon
            // would go missing anyway.
            self.updatePresenceScanning()
        }
        power.onResume = { [weak self] in
            guard let self else { return }
            self.suspendReason = nil
            self.render(state: .disconnected)
            self.server.resume()
            self.updatePresenceScanning()
        }
    }

    /// The auto lock: the scanner measures, this decides when to act on it.
    ///
    /// Locking is deliberately hard to trigger. It needs the feature switched on
    /// here, the phone to have been recognised at least once, the phone not to
    /// have switched its beacon off, no pause in effect, the Mac awake and the
    /// screen still unlocked. Anything missing means no lock at all.
    private func wirePresence() {
        presence.onArmed = { [weak self] _ in self?.refreshMenuTitles() }
        // The countdown is on screen for the whole grace period, not for a few
        // seconds at the end of it: a panel the user cannot miss is only worth
        // having if it also leaves time to react.
        presence.onLeaving = { [weak self] in
            guard let self else { return }
            self.countdown.show(deviceName: self.phoneName) { [weak self] in
                self?.presence.secondsUntilLock
            }
            self.refreshMenuTitles()
        }
        presence.onReturned = { [weak self] in
            self?.countdown.hide()
            self?.refreshMenuTitles()
        }
        presence.onLock = { [weak self] in
            guard let self else { return }
            self.countdown.hide()
            ScreenLocker.lock()
            self.refreshMenuTitles()
        }
        presence.onAvailabilityChange = { [weak self] _ in self?.refreshMenuTitles() }

        // "Don't lock" means "I am here, my phone is not" - so the feature goes
        // back to square one instead of pausing for a fixed stretch: nothing is
        // locked until the phone has been seen again, and once it has, the auto
        // lock simply works as usual. The timed pause stays as its own menu
        // command for when the user really wants it out of the way.
        countdown.onCancel = { [weak self] in
            guard let self else { return }
            Log.info("User cancelled the lock, waiting for the phone to show up again")
            self.presence.rearm()
            self.refreshMenuTitles()
        }

        // "Lock Now" on the phone, which works whether or not the auto lock is on.
        server.onLockRequested = { [weak self] in
            guard let self else { return }
            self.countdown.hide()
            guard !ScreenLocker.isScreenLocked else {
                Log.info("The phone asked for a lock, but the screen is already locked")
                return
            }
            ScreenLocker.lock()
            self.presence.rearm()
            self.refreshMenuTitles()
        }

        // Walking into a network the user marked safe is the same kind of event
        // as closing the lid: it changes whether there is anything to listen for.
        network.onChange = { [weak self] _ in self?.updatePresenceScanning() }

        server.onPresencePreference = { [weak self] enabled in
            guard let self else { return }
            self.phoneAllowsBeacon = enabled
            self.updatePresenceScanning()
        }

        // Nothing to lock while the screen is already locked, and after it is
        // unlocked by hand the phone has to be seen again before arming.
        lockStateObservers = ScreenLocker.observeLockState(
            onLocked: { [weak self] in
                self?.isScreenLocked = true
                self?.updatePresenceScanning()
            },
            onUnlocked: { [weak self] in
                self?.isScreenLocked = false
                self?.updatePresenceScanning()
            }
        )
    }

    /// Single place that decides whether the radio should be listening at all.
    private func updatePresenceScanning() {
        // knownPairingCode, not pairingCode: this runs on the main thread and
        // must never wait for the keychain.
        let code = settings.knownPairingCode
        // Every reason is spelled out: a security feature that silently does
        // nothing is the worst of both worlds.
        let blockers = [
            settings.autoLockEnabled ? nil : "the auto lock is switched off",
            phoneAllowsBeacon ? nil : "the phone switched its beacon off",
            settings.autoLockSnoozeUntil == nil ? nil : "the auto lock is paused",
            power.isSuspended ? "the Mac is suspended" : nil,
            isScreenLocked ? "the screen is already locked" : nil,
            (code?.isEmpty ?? true) ? "the pairing code is not loaded yet" : nil,
            safeNetworkName.map { "the Mac is on a safe network (\($0))" },
        ].compactMap { $0 }

        if let code, blockers.isEmpty {
            presence.settings = settings.presenceSettings
            presence.start(pairingCode: code)
        } else {
            if presence.isRunning {
                presence.stop()
                countdown.hide()
            }
            Log.info("Not listening for the phone: \(blockers.joined(separator: ", "))")
        }
        refreshMenuTitles()
    }

    /// The safe network this Mac is on, nil when it is on none. There is no name
    /// to give it - macOS keeps those to itself - so it goes by its identity.
    private var safeNetworkName: String? {
        guard let id = network.currentProfileID, safeNetworks.isSafe(id) else { return nil }
        return CurrentNetwork.shortForm(id)
    }

    private func snooze(for seconds: TimeInterval) {
        settings.autoLockSnoozeUntil = Date().addingTimeInterval(seconds)
        countdown.hide()
        updatePresenceScanning()

        snoozeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updatePresenceScanning() }
        snoozeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1, execute: work)
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

    /// What to call the phone in the countdown panel.
    private var phoneName: String {
        server.connectedDeviceName ?? settings.pairedDeviceName ?? "Your phone"
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

    // MARK: - Photos

    private func wirePhotos() {
        // Everything the sink and the coordinator do goes through this one path,
        // so the server never learns what Photos is.
        server.makeFileSink = { [weak self] downloads in
            guard let self else { return FileReceiver(directory: downloads) }
            let sink = PhotoRoutingSink(
                downloads: FileReceiver(directory: downloads),
                importer: self.photoImporter,
                acceptsPhotos: { Settings.shared.photosEnabled }
            )
            sink.onImportFailed = { [weak self] name, reason in
                DispatchQueue.main.async { self?.notifier.fileFailed(name: name, reason: reason) }
            }
            return sink
        }
        server.onPhotoManifest = { [weak self] payload, ok, reason in
            guard Settings.shared.photosEnabled else { return }
            self?.photoSync.handle(manifest: payload, ok: ok, reason: reason)
        }
        // A photo transfer speaks on its own line only. It gets no notification
        // and no "Received: …" entry: a holiday's worth of photos arriving is
        // background work, and the file line belongs to what the user asked for.
        server.onPhotoProgress = { [weak self] name, received, total in
            guard let self else { return }
            self.photoTransfer = Self.progressSummary(name: name, done: received, total: total)
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onPhotoStored = { [weak self] _ in
            self?.photoTransfer = nil
            self?.refreshPhotoReport()
        }
        photoSync.onReport = { [weak self] report in
            self?.photoReport = report
            self?.refreshMenuTitles()
            self?.settingsWindow?.refreshFromMenu()
        }
        photoImporter.onImported = { [weak self] name in
            Log.info("Added \(name) to Photos")
            // The count has to be re-read, not remembered: the import finishes on
            // its own queue, well after the cycle that asked for it published its
            // report, so a cached number would sit there saying zero.
            self?.refreshPhotoReport()
        }
        // What the user deleted in Photos themselves is noticed once at startup,
        // so those photos are not offered again from the very first cycle. The
        // report is taken afterwards, so the menu says what is really in the
        // library from the first time it is opened rather than showing zero until
        // some cycle happens to run.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard Settings.shared.photosEnabled else { return }
            self?.photoImporter.reconcile()
            self?.refreshPhotoReport()
        }
    }

    /// Takes a fresh report and shows it. Safe from any thread.
    private func refreshPhotoReport() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.photoReport = self.photoSync.report
            self.refreshMenuTitles()
            self.settingsWindow?.refreshFromMenu()
        }
    }

    /// One line about the photo sync, or nil when it has nothing to say.
    private var photoSummary: String? {
        guard settings.photosEnabled else { return nil }
        if let photoTransfer { return "Photos: \(photoTransfer)" }
        if let refusal = photoReport.refusal { return "Photos: \(refusal)" }
        let readiness = photoImporter.readiness
        guard readiness.canImport else { return "Photos: \(readiness.summary)" }
        if photoReport.awaitingApproval > 0 {
            return "Photos: \(photoReport.awaitingApproval) waiting for your go-ahead"
        }
        return "Photos: \(photoReport.imported) imported"
    }

    @objc private func approvePhotos() {
        photoSync.approveWaitingPlan()
    }

    /// The one place anything leaves the Photos library. macOS puts its own
    /// confirmation in front of this, which is exactly why it is a menu item: an
    /// alert that appears by itself, twice an hour, is not acceptable.
    @objc private func removePhotos() {
        switch photoSync.removeWaitingPhotos() {
        case .cancelledByUser:
            Log.info("Removal cancelled; the photos stay on the list")
        case .failed(let reason):
            notifier.fileFailed(name: "Photos", reason: reason)
        case .deleted, .nothingToDo:
            break
        }
        refreshMenuTitles()
    }

    @objc private func syncPhotosNow() {
        photoSync.syncNow()
    }

    /// Asks the system for the Photos library. The window is brought forward
    /// first: the alert is drawn by macOS, and an accessory app is not frontmost,
    /// so otherwise it opens behind whatever the user is reading.
    private func requestPhotoAccess() {
        NSApp.activate(ignoringOtherApps: true)
        photoImporter.readiness == .notDetermined
            ? PhotoKitLibrary().requestAuthorization { [weak self] readiness in
                Log.info("Photos access: \(readiness.summary)")
                self?.refreshMenuTitles()
                self?.settingsWindow?.refreshFromMenu()
            }
            : Log.info("Photos access: \(photoImporter.readiness.summary)")
    }

    // MARK: - Settings

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(hooks: makeSettingsHooks())
        }
        settingsWindow?.present()
    }

    /// The window changes settings; these are the paths that make a change take
    /// effect, and they are the same ones the menu uses.
    private func makeSettingsHooks() -> SettingsHooks {
        SettingsHooks(
            applyPort: { [weak self] port in
                guard let self else { return }
                self.settings.port = port
                self.server.restart()
                self.refreshMenuTitles()
            },
            regeneratePairingCode: { [weak self] in
                guard let self else { return "" }
                let code = self.settings.regeneratePairingCode()
                self.server.restart()
                // The beacon UUID is derived from the code, so the scan has to
                // be pointed at the new one.
                self.updatePresenceScanning()
                return code
            },
            autoLockChanged: { [weak self] in self?.updatePresenceScanning() },
            toggleSnooze: { [weak self] in self?.toggleSnooze() },
            liveReading: { [weak self] in self?.autoLockSummary ?? "" },
            downloadsPath: { [weak self] in self?.server.destinationDirectory.path ?? "" },
            revealDownloads: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.server.destinationDirectory)
            },
            photoReport: { [weak self] in self?.photoReport ?? PhotoSyncReport() },
            photoReadiness: { [weak self] in
                guard Settings.shared.photosEnabled else { return "not asked for yet" }
                return self?.photoImporter.readiness.summary ?? "unknown"
            },
            photosEnabledChanged: { [weak self] _ in self?.refreshMenuTitles() },
            requestPhotoAccess: { [weak self] in
                // Only ever from a click: an accessory app asking at launch would
                // put a system alert behind whatever the user is looking at.
                self?.requestPhotoAccess()
            },
            approvePhotos: { [weak self] in self?.approvePhotos() },
            removePhotos: { [weak self] in self?.removePhotos() },
            syncPhotosNow: { [weak self] in self?.syncPhotosNow() },
            revealPhotoAlbum: {
                guard let photos = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Photos"
                ) else { return }
                NSWorkspace.shared.openApplication(at: photos, configuration: .init())
            },
            currentNetworkID: { [weak self] in self?.network.currentProfileID },
            safeNetworks: { [weak self] in self?.safeNetworks.all ?? [] },
            addCurrentNetwork: { [weak self] in
                guard let self, let id = self.network.currentProfileID else { return }
                self.safeNetworks.add(id: id)
                self.updatePresenceScanning()
            },
            removeNetwork: { [weak self] id in
                guard let self else { return }
                self.safeNetworks.remove(id: id)
                self.updatePresenceScanning()
            }
        )
    }

    // MARK: - Auto lock actions

    @objc private func toggleAutoLock() {
        settings.autoLockEnabled = !settings.autoLockEnabled
        if settings.autoLockEnabled {
            // Turning it back on should not inherit an old pause.
            settings.autoLockSnoozeUntil = nil
            if settings.knownPairingCode?.isEmpty ?? false {
                showAlert(
                    title: "No pairing code yet",
                    message: "Pair the phone first: the beacon the Mac listens for is derived from the pairing code."
                )
            }
        }
        Log.info("Auto lock \(settings.autoLockEnabled ? "enabled" : "disabled")")
        updatePresenceScanning()
    }

    @objc private func toggleSnooze() {
        if settings.autoLockSnoozeUntil == nil {
            snooze(for: 3600)
        } else {
            settings.autoLockSnoozeUntil = nil
            snoozeWorkItem?.cancel()
            updatePresenceScanning()
        }
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

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func summarize(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count <= 40 ? flattened : String(flattened.prefix(40)) + "…"
    }
}

private extension String {
    /// The scanner phrases its availability as a sentence fragment; the menu
    /// wants it to start a line.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
