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
        readAlbumName: { Settings.shared.photosAlbumName },
        readAlbumIdentifier: { Settings.shared.photosAlbumIdentifier },
        writeAlbumIdentifier: { Settings.shared.photosAlbumIdentifier = $0 }
    )
    private lazy var photoSync = PhotoSyncCoordinator(
        importer: photoImporter,
        approvesAdditions: { Settings.shared.photosApproveAdditions }
    ) { [weak self] keys, id in
        // Whether the ask reached the phone decides whether those rows may be
        // crossed off the list, so the answer is carried back rather than dropped.
        self?.server.requestPhotos(keys: keys, manifestId: id) ?? false
    }
    /// The pace of the photo sync, which used to belong to the phone.
    private lazy var photoScheduler = PhotoSyncScheduler(
        intervalMinutes: { Settings.shared.photosIntervalMinutes },
        isEligible: { [weak self] in
            guard let self else { return false }
            // Nothing is asked while the phone is away, while the feature is off,
            // or in the middle of a transfer. A Mac that went to sleep needs no
            // special case: the server suspends, so `isConnected` says no.
            return Settings.shared.photosEnabled
                && self.server.isConnected
                && self.photoTransfer == nil
        },
        lastCycleAt: { [weak self] in self?.photoSync.lastCycleAt },
        fire: { [weak self] in self?.photoSync.syncNow() }
    )
    private var photoReport = PhotoSyncReport()
    /// The photo in flight, shown on the photo line while it arrives.
    private var photoTransfer: String?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pingMenuItem = NSMenuItem(title: "Ping phone", action: #selector(pingPhone), keyEquivalent: "p")
    private let sendMenuItem = NSMenuItem(title: "Send clipboard now", action: #selector(sendClipboardNow), keyEquivalent: "s")
    private let sendFilesMenuItem = NSMenuItem(title: "Send files to phone…", action: #selector(sendFiles), keyEquivalent: "o")
    private let downloadsMenuItem = NSMenuItem(title: "Open Downloads folder", action: #selector(openDownloads), keyEquivalent: "")
    private let autoLockMenuItem = NSMenuItem(title: "Lock when the phone leaves", action: #selector(toggleAutoLock), keyEquivalent: "")
    private let snoozeMenuItem = NSMenuItem(title: "Pause auto lock for an hour", action: #selector(toggleSnooze), keyEquivalent: "")
    private let photoWindowMenuItem = NSMenuItem(title: "Photo sync…", action: #selector(showPhotoSync(_:)), keyEquivalent: "")
    private let photoSyncNowMenuItem = NSMenuItem(title: "Sync photos now", action: #selector(syncPhotosNow), keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
    private let quitMenuItem = NSMenuItem(title: "Quit MacDroidSync", action: #selector(quit), keyEquivalent: "q")

    private let notifier = Notifier()
    private let countdown = LockCountdownWindow()
    /// Built on first use: the window is the exception in a menu bar app, not
    /// something every session needs.
    private var settingsWindow: SettingsWindowController?
    /// Same rule as the settings window, and it never opens by itself: the
    /// operator asks for it from the menu or from a notification.
    private var photoSyncWindow: PhotoSyncWindowController?
    /// Keys the operator has already been told about, so a list that stands for
    /// a week does not raise a banner on every cycle.
    private var notifiedPhotoKeys: Set<String> = []
    private var lastPhotoNoticeAt: Date?
    /// The first report after launch says nothing: a backlog from before the
    /// restart is not news.
    private var photoNoticesArmed = false
    private var replacedFlushWork: DispatchWorkItem?
    private lazy var serviceProvider = ServiceProvider { [weak self] urls in
        self?.enqueue(files: urls)
    }

    private var displayState: PeerState = .disconnected
    private var failureMessage: String?
    private var suspendReason: String?
    private var lastReceivedFile: URL?
    /// A file arrived and nobody has looked at the menu since.
    ///
    /// The other half of the dot in the menu bar, and the half that clears
    /// itself: a delivered file is news until it has been seen, while a photo
    /// waiting for a decision stays a request until it is answered.
    private var hasUnseenFile = false
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
        replacedFlushWork?.cancel()
        photoScheduler.stop()
        settingsWindow?.close()
        photoSyncWindow?.close()
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

        for item in [
            pingMenuItem, sendMenuItem, sendFilesMenuItem, downloadsMenuItem,
            autoLockMenuItem, snoozeMenuItem, settingsMenuItem, quitMenuItem,
            photoWindowMenuItem, photoSyncNowMenuItem,
        ] {
            item.target = self
        }

        // What the menu carries is the connection state and the handful of
        // things worth doing from the menu bar. Everything that is set once and
        // then left alone lives in the settings window, and the running
        // commentary - the last clipboard, the last file, the live reading, the
        // photo count - is not here either: the icon and the notifications say
        // what needs saying, and the settings window has the numbers. What is
        // not worth doing right now is greyed out rather than taken away, so
        // the menu keeps its shape.
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(pingMenuItem)
        menu.addItem(sendMenuItem)
        menu.addItem(.separator())
        menu.addItem(sendFilesMenuItem)
        menu.addItem(downloadsMenuItem)
        menu.addItem(.separator())
        menu.addItem(autoLockMenuItem)
        menu.addItem(snoozeMenuItem)
        menu.addItem(.separator())
        // The window where every decision is made, then the manual run.
        menu.addItem(photoWindowMenuItem)
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
        // Opening the menu counts as having seen it: the dot in the icon has
        // done its job, and the Downloads entry is lit for whoever wants the file.
        hasUnseenFile = false
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

        sendFilesMenuItem.isEnabled = true

        renderIcon()
        // Stays in the menu whatever the count, because it is the only way into
        // the window - but the window has nothing to show until something waits
        // in it, so the entry is greyed out rather than removed the rest of the
        // time. The count is gated the same way the dot in the icon is.
        let decisions = settings.photosEnabled ? photoReport.pendingDecisions : 0
        photoWindowMenuItem.title = decisions == 0
            ? "Photo sync…"
            : "Photo sync — \(decisions) waiting…"
        photoWindowMenuItem.isEnabled = decisions > 0
        photoSyncNowMenuItem.isEnabled = connected && settings.photosEnabled

        downloadsMenuItem.title = "Open \(server.destinationDirectory.lastPathComponent) folder"
        // Nothing worth opening until the phone has actually delivered a file.
        // Remembered for the life of the process only: no record of received
        // files is kept anywhere, and the folder's own contents say nothing -
        // it is the user's Downloads, full of things that never saw the phone.
        downloadsMenuItem.isEnabled = lastReceivedFile != nil

        let autoLock = settings.autoLockEnabled
        autoLockMenuItem.state = autoLock ? .on : .off
        // On a safe network the lock is not armed in the first place, so a pause
        // would pause nothing; one already running simply runs out on its own.
        snoozeMenuItem.isEnabled = autoLock && safeNetworkName == nil
        snoozeMenuItem.title = settings.autoLockSnoozeUntil == nil
            ? "Pause auto lock for an hour"
            : "Resume auto lock"

        // The window shows the same settings from the other side, so it is
        // refreshed from the one place that already knows they changed.
        settingsWindow?.refresh()
    }

    /// The live reading is the only practical way to calibrate the threshold:
    /// walk away and watch what it says. It is shown in the settings window next
    /// to the threshold field, which is where the calibrating happens; the menu
    /// no longer carries it.
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
        renderIcon()
        refreshMenuTitles()
    }

    /// The icon, and the dot that says the sync is waiting for an answer.
    ///
    /// Separate from `render(state:)` because the two things that decide what
    /// the icon looks like change independently: the connection comes from the
    /// server, and the dot from a photo cycle that may not have touched the
    /// connection at all.
    private func renderIcon() {
        let decisions = settings.photosEnabled ? photoReport.pendingDecisions : 0
        let attention = decisions > 0 || hasUnseenFile
        let button = statusItem.button
        button?.image = StatusIcon.image(for: displayState, needsAttention: attention)
        button?.alphaValue = StatusIcon.alpha(for: displayState, needsAttention: attention)

        var lines = [StatusIcon.accessibilityDescription(for: displayState)]
        if decisions > 0 { lines.append("\(decisions) photo item(s) waiting for a decision") }
        if hasUnseenFile, let name = lastReceivedFile?.lastPathComponent {
            lines.append("received \(name)")
        }
        button?.toolTip = lines.joined(separator: " - ")
        // The dot is a shape and says nothing on its own, so the reason for it
        // goes where VoiceOver will read it.
        button?.setAccessibilityLabel(button?.toolTip)
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
                // The configuration is not sent from here: the session sends it
                // inside the handshake, which is both earlier and ordered against
                // the first request. Doing it again here only put a second copy
                // on the wire.
                self.photoScheduler.connected()
            }
        }
        server.onClipboardReceived = { [weak self] text in
            guard let self else { return }
            self.watcher.apply(remoteText: text)
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
            // Progress arrives at least every 200 ms, so the icon stays lit for
            // the whole transfer.
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onFileReceived = { [weak self] url, _ in
            guard let self else { return }
            self.lastReceivedFile = url
            self.hasUnseenFile = true
            self.notifier.fileReceived(at: url, from: self.server.connectedDeviceName ?? "your phone")
            self.flashTransfer()
            self.refreshMenuTitles()
        }
        server.onFileFailed = { [weak self] name, reason in
            guard let self else { return }
            self.notifier.fileFailed(name: name, reason: reason)
            self.refreshMenuTitles()
        }
        server.onOutgoingProgress = { [weak self] name, sent, total in
            guard let self else { return }
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
            flashTransfer()
        } else {
            pending.store(text: text)
            Log.info("Phone unavailable, clipboard queued for the next connection")
        }
        refreshMenuTitles()
    }

    private func flushPending() {
        guard let item = pending.pending else { return }
        Log.info("Flushing the queued clipboard from \(Date(timeIntervalSince1970: Double(item.ts) / 1000))")
        if server.sendClipboard(text: item.text) {
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
            self.notifier.fileFailed(name: missing.name, reason: "the file is no longer there")
        }) else {
            refreshMenuTitles()
            return
        }

        do {
            if try server.sendFile(url: item.url) {
                sendingItemId = item.id
                flashTransfer()
            }
        } catch {
            // Nothing about this file can ever work: drop it and move on.
            outbox.remove(id: item.id)
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
                notifier.fileFailed(name: name, reason: reason)
            }
        }
        Log.error("Sending \(name) failed: \(reason)")
        refreshMenuTitles()
        drainOutbox()
    }

    /// What to call the phone in the countdown panel.
    private var phoneName: String {
        server.connectedDeviceName ?? settings.pairedDeviceName ?? "Your phone"
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
            Log.info("No phone connected, \(panel.urls.count) file(s) queued")
        }
        enqueue(files: panel.urls)
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
        // Worked out at the moment of the handshake, on the session's own queue,
        // so it always reaches the phone before the first request of a session.
        server.makePhotoConfig = { Self.photoConfig() }
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
        // Deliberately not hung off `refreshMenuTitles`, which runs several
        // times a second during a transfer: reloading the table that often
        // would fight whoever is reading it.
        photoSync.onPendingChanged = { [weak self] _ in
            self?.photoSyncWindow?.refreshFromMenu()
        }
        photoSync.onDecisionsNeeded = { [weak self] rows in
            self?.announcePhotoDecisions(rows)
        }
        // The banner's only job is to open the window.
        notifier.onOpenPhotoSync = { [weak self] in self?.showPhotoSync(nil) }
        photoScheduler.start()
        photoImporter.onImported = { [weak self] name in
            Log.info("Added \(name) to Photos")
            // An edit lands as an import plus a removal, because Photos offers no
            // way to replace an asset's contents. The removal half follows on its
            // own so that approving "Update" means what it says.
            self?.scheduleReplacedFlush()
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
            // What is still waiting to leave Photos lives in the index. Bringing
            // it back onto the list at startup is what stops a pending removal
            // from being invisible until the next manifest turns up.
            self?.photoSync.refreshPending()
            self?.refreshPhotoReport()
        }
    }

    /// Takes out the copies edits replaced, once the arrivals have settled.
    ///
    /// Debounced rather than immediate: bytes arrive one photo at a time, and
    /// macOS puts up its own alert once per call into the library. Waiting for
    /// the run to finish turns twenty alerts into one. The wait also keeps this
    /// honest about where it came from - it is the tail of the operator's own
    /// click, seconds earlier, not something that happens by itself.
    private func scheduleReplacedFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replacedFlushWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                switch self.photoSync.flushReplacedVersions() {
                case .cancelledByUser:
                    Log.info("The replaced copies were left in Photos; they stay on the list")
                case .failed(let why):
                    Log.error("Could not remove the replaced copies: \(why)")
                case .deleted, .nothingToDo:
                    break
                }
                self.refreshPhotoReport()
            }
            self.replacedFlushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    /// Takes a fresh report and shows it. Safe from any thread.
    private func refreshPhotoReport() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.photoReport = self.photoSync.report
            self.refreshMenuTitles()
            self.settingsWindow?.refreshFromMenu()
            self.photoSyncWindow?.refreshFromMenu()
        }
    }

    @objc private func syncPhotosNow() {
        requestPhotoManifest()
    }

    /// The one path a manual "ask the phone now" takes.
    ///
    /// Both the menu item and the button in the settings window come here, so
    /// that asking by hand also restarts the countdown - otherwise the timer
    /// would fire moments later and put a second manifest on the wire.
    private func requestPhotoManifest() {
        photoScheduler.noteAsked()
        photoSync.syncNow()
    }

    /// What the phone is told about photos: the settings, worked out fresh.
    private static func photoConfig() -> PhotoPayload {
        let settings = Settings.shared
        return PhotoPayload(
            enabled: settings.photosEnabled,
            lastDays: settings.photosLastDays,
            maxItemBytes: settings.photosMaxItemBytes
        )
    }

    /// Sends it now, if the phone is here. Nothing is queued when it is not: the
    /// handshake works it out again from the same settings.
    private func pushPhotoConfig() {
        server.sendPhotoConfig(Self.photoConfig())
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

    // MARK: - The sync window

    @objc private func showPhotoSync(_ sender: Any?) {
        if photoSyncWindow == nil {
            photoSyncWindow = PhotoSyncWindowController(hooks: makePhotoSyncHooks())
        }
        photoSyncWindow?.present()
    }

    private func makePhotoSyncHooks() -> PhotoSyncHooks {
        PhotoSyncHooks(
            pendingActions: { [weak self] in self?.photoSync.pendingActions ?? [] },
            synchronize: { [weak self] keys in
                guard let self else { return PhotoActionOutcome() }
                let outcome = self.photoSync.synchronize(keys: keys)
                self.refreshPhotoReport()
                return outcome
            },
            ignore: { [weak self] keys in
                guard let self else { return }
                self.photoSync.ignore(keys: keys)
                self.refreshPhotoReport()
            },
            syncNow: { [weak self] in self?.syncPhotosNow() },
            status: { [weak self] in
                guard let self else { return nil }
                guard Settings.shared.photosEnabled else {
                    return "Photo sync is switched off in Settings."
                }
                if let refusal = self.photoReport.refusal {
                    return "The phone is not describing its camera folder: \(refusal)"
                }
                let readiness = self.photoImporter.readiness
                return readiness.canImport ? nil : "Photos access: \(readiness.summary)"
            }
        )
    }

    /// Posts at most one banner for one list, and only for rows nobody has seen.
    ///
    /// Five separate brakes, because the cycle runs twice an hour and the list
    /// can stand for days: only unseen keys, not while the window is open, not
    /// within six hours of the last one unless a real wave arrived, nothing on
    /// the first report after launch, and one fixed notification identifier so a
    /// new banner replaces the old rather than stacking on it.
    private func announcePhotoDecisions(_ rows: [PhotoPendingAction]) {
        guard Settings.shared.photosEnabled else { return }
        let keys = Set(rows.map(\.key))
        guard photoNoticesArmed else {
            photoNoticesArmed = true
            notifiedPhotoKeys = keys
            return
        }
        guard !keys.isEmpty else {
            notifiedPhotoKeys = []
            return
        }
        guard photoSyncWindow?.window?.isVisible != true else {
            notifiedPhotoKeys = keys
            return
        }
        let fresh = keys.subtracting(notifiedPhotoKeys)
        guard !fresh.isEmpty else { return }
        if let last = lastPhotoNoticeAt,
           Date().timeIntervalSince(last) < Self.photoNoticeInterval,
           fresh.count < Self.photoNoticeBurst {
            notifiedPhotoKeys = keys
            return
        }
        notifiedPhotoKeys = keys
        lastPhotoNoticeAt = Date()
        notifier.photosNeedDecision(summary: PhotoPendingAction.summary(of: rows))
    }

    private static let photoNoticeInterval: TimeInterval = 6 * 3600
    private static let photoNoticeBurst = 25

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
            openPhotoSyncWindow: { [weak self] in self?.showPhotoSync(nil) },
            photoSettingsChanged: { [weak self] in
                guard let self else { return }
                // The phone holds the configuration only for a session, so a
                // change has to go out now as well as at the next handshake.
                self.pushPhotoConfig()
                self.refreshPhotoReport()
            },
            resetPhotoBaseline: { [weak self] in
                guard let self else { return }
                self.photoSync.resetBaseline()
                // Nothing changes until the phone describes itself again, so the
                // ask goes out at once rather than waiting for the interval.
                self.requestPhotoManifest()
                self.refreshPhotoReport()
            },
            syncPhotosNow: { [weak self] in self?.requestPhotoManifest() },
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
}

private extension String {
    /// The scanner phrases its availability as a sentence fragment; the menu
    /// wants it to start a line.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
