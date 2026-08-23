import AppKit
import MacDroidSyncCore

/// What the settings window is allowed to do to the running app.
///
/// The window owns no server, no scanner and no radio: every change it makes
/// travels through one of these closures, which are the same code paths the menu
/// used to call. That way a port changed here restarts the listener exactly as a
/// port changed from the menu did, and there is no second, subtly different way
/// of applying a setting.
struct SettingsHooks {
    var applyPort: (UInt16) -> Void = { _ in }
    var regeneratePairingCode: () -> String = { "" }
    /// Anything that can change whether the Mac should be listening for the phone.
    var autoLockChanged: () -> Void = {}
    var toggleSnooze: () -> Void = {}
    /// The live `Phone: -58 dBm (near)` line, computed by the menu controller.
    var liveReading: () -> String = { "" }
    var downloadsPath: () -> String = { "" }
    var revealDownloads: () -> Void = {}

    /// Photo sync. The window shows what the coordinator decided and offers the
    /// two things only the operator may set off; it never imports or deletes.
    var photoReport: () -> PhotoSyncReport = { PhotoSyncReport() }
    var photoReadiness: () -> String = { "" }
    var photosEnabledChanged: (Bool) -> Void = { _ in }
    var requestPhotoAccess: () -> Void = {}
    var approvePhotos: () -> Void = {}
    var removePhotos: () -> Void = {}
    var syncPhotosNow: () -> Void = {}
    var revealPhotoAlbum: () -> Void = {}

    /// Identity of the Wi-Fi network this Mac is on, nil when it is on none.
    var currentNetworkID: () -> String? = { nil }
    var safeNetworks: () -> [SafeNetworkStore.Network] = { [] }
    var addCurrentNetwork: () -> Void = {}
    var removeNetwork: (String) -> Void = { _ in }
}

/// The settings window: everything that is configured once and then left alone.
///
/// The menu keeps the state and the actions; this keeps the knobs. Both read and
/// write the same `Settings`, so `refresh()` exists to keep the two in step -
/// and it only ever writes values into controls, never fires their actions,
/// which is what stops the two from bouncing changes off each other.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {

    private let settings = Settings.shared
    private let hooks: SettingsHooks

    // General
    private let pairingField = NSTextField(labelWithString: "")
    private let portField = NSTextField(string: "")
    private let launchAtLoginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let downloadsLabel = NSTextField(labelWithString: "")

    // Auto lock
    private let autoLockBox = NSButton(checkboxWithTitle: "Lock when the phone leaves", target: nil, action: nil)
    private var presetButtons: [NSButton] = []
    private let thresholdField = NSTextField(string: "")
    private let liveLabel = NSTextField(labelWithString: "")
    private let snoozeLabel = NSTextField(labelWithString: "")
    private let snoozeButton = NSButton(title: "Pause for an hour", target: nil, action: nil)

    // Photos
    private let photosBox = NSButton(
        checkboxWithTitle: "Add photos and videos from the phone to Photos", target: nil, action: nil
    )
    private let photoAccessLabel = NSTextField(labelWithString: "")
    private let photoAccessButton = NSButton(title: "Grant access…", target: nil, action: nil)
    private let photoCountsLabel = NSTextField(labelWithString: "")
    private let photoWaitingLabel = NSTextField(labelWithString: "")
    private let photoApproveButton = NSButton(title: "Import…", target: nil, action: nil)
    private let photoRemoveButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let photoWindowLabel = NSTextField(labelWithString: "")
    private let photoSkippedLabel = NSTextField(wrappingLabelWithString: "")

    // Safe networks
    private let networkTable = NSTableView()
    private let addNetworkButton = NSButton(title: "+", target: nil, action: nil)
    private let removeNetworkButton = NSButton(title: "−", target: nil, action: nil)
    private let networkStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// Identity of the network in use, shown so it can be matched against the list.
    private let currentNetworkLabel = NSTextField(labelWithString: "")
    /// What the table shows, so the data source can never disagree with it.
    private var networks: [SafeNetworkStore.Network] = []

    private var ticker: DispatchSourceTimer?
    private var tabs: NSTabView?
    /// Width of the roomiest tab, so the window never jumps sideways.
    private var bodyWidth: CGFloat = 0

    init(hooks: SettingsHooks) {
        self.hooks = hooks

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacDroidSync Settings"
        // Reopening a released window crashes; an accessory app opens this one
        // again and again over a session.
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = buildTabs()
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Showing

    func present() {
        // An accessory app has no Dock icon to click, so it has to ask for the
        // focus itself or the window opens behind whatever is in front.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Only now: refresh does nothing while the window is off screen, so
        // filling the fields has to come after it is up.
        //
        fetchPairingCodeIfNeeded()
        refresh()
        // One turn of the run loop later: the wrapping hints only know their real
        // height once they have been laid out at the window's width, and asking
        // before that gives a window taller than it needs to be.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitWindow(to: self.tabs?.selectedTabViewItem, animated: false)
        }
        startTicking()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        fitWindow(to: tabViewItem, animated: true)
    }

    /// Each tab gets the window height it needs, instead of every tab getting the
    /// height of the roomiest one. The chrome is measured rather than guessed:
    /// the difference between the content view and the tab view's own content
    /// rect is exactly the padding plus the strip of tab buttons.
    private func fitWindow(to item: NSTabViewItem?, animated: Bool) {
        guard let window,
              let content = window.contentView,
              let tabs,
              let body = item?.view
        else { return }
        content.layoutSubtreeIfNeeded()
        let inner = tabs.contentRect
        guard inner.width > 0, inner.height > 0 else { return }

        let target = NSSize(
            width: content.frame.width - inner.width + bodyWidth,
            height: content.frame.height - inner.height + body.fittingSize.height
        )
        let sized = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var frame = window.frame
        // Windows grow downwards, so the title bar has to be held in place.
        frame.origin.y += frame.height - sized.height
        frame.size = sized.size
        window.setFrame(frame, display: true, animate: animated)
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.cancel()
        ticker = nil
        // Abandon whatever was typed but never applied, while the window is
        // still on screen and `refresh` still does something. Closing has to be
        // the moment for it: on reopening, AppKit hands the field editor back
        // with its old text, and `refresh` leaves a field being edited alone by
        // design - so the window would show a port that is not the one in force.
        window?.endEditing(for: nil)
        refresh()
    }

    /// The live reading only moves while somebody is looking at it.
    private func startTicking() {
        guard ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.liveLabel.stringValue = self?.hooks.liveReading() ?? ""
        }
        timer.resume()
        ticker = timer
    }

    // MARK: - Keeping up with the menu

    /// Pulls every control back in line with `Settings`. Called after any change
    /// made here and from the menu controller, so the two can never disagree.
    func refresh() {
        guard window?.isVisible == true else { return }

        // Never overwrite a field the user is typing in: committing whatever is
        // half typed - or throwing it away mid-keystroke - is the same class of
        // bug as a switch that quietly saves a text field.
        write(String(settings.port), into: portField)
        pairingField.stringValue = settings.knownPairingCode ?? "Loading…"
        launchAtLoginBox.state = settings.launchAtLoginEnabled ? .on : .off
        downloadsLabel.stringValue = hooks.downloadsPath()

        let autoLock = settings.autoLockEnabled
        autoLockBox.state = autoLock ? .on : .off
        presetButtons.forEach { $0.state = $0.title == settings.autoLockPreset ? .on : .off }
        let override = settings.autoLockAwayThreshold
        write(
            override < 0
                ? String(format: "%.0f", override)
                : String(format: "%.0f", settings.presenceSettings.awayThreshold),
            into: thresholdField
        )
        thresholdField.placeholderString = String(
            format: "%.0f", settings.presenceSettings.awayThreshold
        )

        for control in presetButtons + [thresholdField, snoozeButton] {
            control.isEnabled = autoLock
        }
        liveLabel.stringValue = hooks.liveReading()

        if let until = settings.autoLockSnoozeUntil {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            snoozeLabel.stringValue = "Paused until \(formatter.string(from: until))"
            snoozeButton.title = "Resume now"
        } else {
            snoozeLabel.stringValue = autoLock ? "Running" : "Switched off"
            snoozeButton.title = "Pause for an hour"
        }

        refreshNetworks()
        refreshPhotos()
    }

    /// Refresh after a change made **here**. The field editor is dismissed
    /// first, so `refresh` is free to rewrite a field that still holds the focus:
    /// its guard is there to protect somebody typing, not to freeze a value the
    /// user just changed with a button.
    private func refreshAfterChange() {
        window?.endEditing(for: nil)
        refresh()
    }

    private func write(_ value: String, into field: NSTextField) {
        guard field.currentEditor() == nil else { return }
        field.stringValue = value
    }

    /// The first keychain read can take seconds, so it never happens on the main
    /// thread; until it lands the field says so.
    private func fetchPairingCodeIfNeeded() {
        guard settings.knownPairingCode == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Settings.shared.pairingCode
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    // MARK: - Safe networks

    private func refreshNetworks() {
        let selected = selectedNetwork?.id
        networks = hooks.safeNetworks()
        networkTable.reloadData()
        // Keeps the selection on the same network rather than the same row index,
        // which after a removal would jump to a neighbour.
        if let selected, let row = networks.firstIndex(where: { $0.id == selected }) {
            networkTable.selectRowIndexes([row], byExtendingSelection: false)
        }

        let current = hooks.currentNetworkID()
        let alreadyListed = current.map { id in networks.contains { $0.id == id } } ?? false
        addNetworkButton.isEnabled = current != nil && !alreadyListed
        addNetworkButton.toolTip = {
            if current == nil { return "This Mac is not on a Wi-Fi network right now." }
            if alreadyListed { return "This network is already on the list." }
            return "Add the network this Mac is on."
        }()
        removeNetworkButton.isEnabled = selectedNetwork != nil

        // The identity of the network in use, so it can be matched against the
        // list by eye. It is the same value the decision compares.
        currentNetworkLabel.stringValue = current.map(CurrentNetwork.shortForm) ?? "not on a Wi-Fi network"

        networkStatusLabel.stringValue = {
            guard current != nil else {
                return "Not on a Wi-Fi network, so the auto lock is running."
            }
            if alreadyListed {
                return "This network is on the list, so the auto lock is standing down."
            }
            return "This network is not on the list, so the auto lock is running."
        }()
    }

    private var selectedNetwork: SafeNetworkStore.Network? {
        let row = networkTable.selectedRow
        guard row >= 0, row < networks.count else { return nil }
        return networks[row]
    }

    /// One press, no questions. There is nothing to ask: the network identifies
    /// itself, and macOS would not give us its name without a permission this
    /// feature has no business holding.
    @objc private func addCurrentNetwork() {
        guard hooks.currentNetworkID() != nil else { return }
        hooks.addCurrentNetwork()
        refreshAfterChange()
    }

    @objc private func removeSelectedNetwork() {
        guard let network = selectedNetwork else { return }
        hooks.removeNetwork(network.id)
        refreshAfterChange()
    }

    // MARK: - The list

    func numberOfRows(in tableView: NSTableView) -> Int { networks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < networks.count else { return nil }
        let field = NSTextField(labelWithAttributedString: attributed(networks[row]))
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeNetworkButton.isEnabled = selectedNetwork != nil
    }

    /// The identity, monospaced so two of them can be compared column by column,
    /// and for the network in use a quiet note saying so. That note is the one
    /// thing the list cannot show by itself.
    private func attributed(_ network: SafeNetworkStore.Network) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: CurrentNetwork.shortForm(network.id),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
        )
        guard network.id == hooks.currentNetworkID() else { return text }
        text.append(NSAttributedString(
            string: "   on this network",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return text
    }

    // MARK: - General actions

    @objc private func copyPairingCode() {
        guard let code = settings.knownPairingCode, !code.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    @objc private func regeneratePairingCode() {
        let confirm = NSAlert()
        confirm.messageText = "Generate a new pairing code?"
        confirm.informativeText = """
            The phone stops connecting until you enter the new code in the Android app. \
            The presence beacon is derived from the code as well, so the auto lock \
            pauses until then too.
            """
        confirm.addButton(withTitle: "Generate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let code = hooks.regeneratePairingCode()
        refreshAfterChange()
        report(title: "New pairing code", message: "\(code)\n\nEnter it in the Android app to reconnect.")
    }

    @objc private func applyPort() {
        let text = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(text), value >= 1024 else {
            report(title: "Invalid port", message: "Use a number between 1024 and 65535.")
            refreshAfterChange()
            return
        }
        hooks.applyPort(value)
        refreshAfterChange()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(launchAtLoginBox.state == .on)
        } catch {
            report(
                title: "Could not update the login item",
                message: "\(error.localizedDescription)\n\nMove MacDroidSync.app to /Applications and try again."
            )
        }
        refreshAfterChange()
    }

    @objc private func revealDownloads() {
        hooks.revealDownloads()
    }

    // MARK: - Auto lock actions

    @objc private func toggleAutoLock() {
        settings.autoLockEnabled = autoLockBox.state == .on
        if settings.autoLockEnabled {
            // Turning it back on should not inherit an old pause.
            settings.autoLockSnoozeUntil = nil
            if settings.knownPairingCode?.isEmpty ?? false {
                report(
                    title: "No pairing code yet",
                    message: "Pair the phone first: the beacon the Mac listens for is derived from the pairing code."
                )
            }
        }
        Log.info("Auto lock \(settings.autoLockEnabled ? "enabled" : "disabled")")
        hooks.autoLockChanged()
        refreshAfterChange()
    }

    @objc private func choosePreset(_ sender: NSButton) {
        settings.autoLockPreset = sender.title
        // A preset brings its own thresholds, so any manual value is dropped.
        settings.autoLockAwayThreshold = 0
        Log.info("Auto lock sensitivity set to \(sender.title)")
        hooks.autoLockChanged()
        refreshAfterChange()
    }

    @objc private func applyThreshold() {
        let text = thresholdField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value < 0, value > -110 else {
            report(title: "Invalid threshold", message: "Use a value between -110 and -1 dBm.")
            refreshAfterChange()
            return
        }
        settings.autoLockAwayThreshold = value
        hooks.autoLockChanged()
        refreshAfterChange()
    }

    @objc private func useThresholdPreset() {
        settings.autoLockAwayThreshold = 0
        hooks.autoLockChanged()
        refreshAfterChange()
    }

    @objc private func toggleSnooze() {
        hooks.toggleSnooze()
        refreshAfterChange()
    }

    // MARK: - Building

    private func buildTabs() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let bodies = [
            pad(buildGeneralTab()), pad(buildAutoLockTab()), pad(buildSafeNetworksTab()),
            pad(buildPhotosTab()), pad(buildAboutTab()),
        ]

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = bodies[0]
        tabs.addTabViewItem(general)

        let autoLock = NSTabViewItem(identifier: "autoLock")
        autoLock.label = "Auto lock"
        autoLock.view = bodies[1]
        tabs.addTabViewItem(autoLock)

        let networks = NSTabViewItem(identifier: "safeNetworks")
        networks.label = "Safe networks"
        networks.view = bodies[2]
        tabs.addTabViewItem(networks)

        let photos = NSTabViewItem(identifier: "photos")
        photos.label = "Photos"
        photos.view = bodies[3]
        tabs.addTabViewItem(photos)

        let about = NSTabViewItem(identifier: "about")
        about.label = "About"
        about.view = bodies[4]
        tabs.addTabViewItem(about)

        // One width for every tab, so switching them does not make the window
        // jump sideways; the height follows whichever tab is showing.
        bodyWidth = bodies.map { $0.fittingSize.width }.max() ?? 0
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: bodyWidth).isActive = true
        tabs.delegate = self
        self.tabs = tabs

        let container = NSView()
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func buildGeneralTab() -> NSView {
        portField.target = self
        portField.action = #selector(applyPort)
        // Return applies, losing the focus does not. By default a text field
        // fires its action on the way out too, which would quietly apply a value
        // the user typed and then walked away from - including on the way to
        // closing the window.
        portField.cell?.sendsActionOnEndEditing = false
        launchAtLoginBox.target = self
        launchAtLoginBox.action = #selector(toggleLaunchAtLogin)

        pairingField.isSelectable = true
        pairingField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        downloadsLabel.font = .systemFont(ofSize: 11)
        downloadsLabel.textColor = .secondaryLabelColor
        downloadsLabel.lineBreakMode = .byTruncatingMiddle

        let grid = NSGridView(views: [
            [label("Pairing code:"), row([
                pairingField,
                button("Copy", #selector(copyPairingCode)),
                button("Regenerate…", #selector(regeneratePairingCode)),
            ])],
            [NSGridCell.emptyContentView, hint("The shared secret both apps derive their keys from. Enter the same code in the Android app.")],
            [label("Port:"), row([sized(portField, width: 90), button("Apply", #selector(applyPort))])],
            [NSGridCell.emptyContentView, hint("Both apps must use the same port. Default is \(Wire.defaultPort).")],
            [label("Startup:"), launchAtLoginBox],
            [label("Incoming files:"), row([downloadsLabel, button("Reveal…", #selector(revealDownloads))])],
        ])
        return configure(grid)
    }

    private func buildAutoLockTab() -> NSView {
        autoLockBox.target = self
        autoLockBox.action = #selector(toggleAutoLock)
        thresholdField.target = self
        thresholdField.action = #selector(applyThreshold)
        thresholdField.cell?.sendsActionOnEndEditing = false
        snoozeButton.target = self
        snoozeButton.action = #selector(toggleSnooze)

        liveLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        snoozeLabel.font = .systemFont(ofSize: 12)
        snoozeLabel.textColor = .secondaryLabelColor

        let presets = NSStackView()
        presets.orientation = .vertical
        presets.alignment = .leading
        presets.spacing = 4
        for preset in [PresenceSettings.fast, .balanced, .cautious] {
            guard let name = preset.presetName else { continue }
            let radio = NSButton(radioButtonWithTitle: name, target: self, action: #selector(choosePreset(_:)))
            radio.toolTip = Self.describe(preset)
            presetButtons.append(radio)
            presets.addView(radio, in: .top)
            presets.addView(hint(Self.describe(preset), indent: 18), in: .top)
        }

        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, autoLockBox],
            [NSGridCell.emptyContentView, hint("The screen is never locked until the phone has been seen at least once.")],
            [label("Sensitivity:"), presets],
            [label("Away threshold:"), row([
                sized(thresholdField, width: 70),
                label("dBm"),
                button("Apply", #selector(applyThreshold)),
                button("Use the preset", #selector(useThresholdPreset)),
            ])],
            [NSGridCell.emptyContentView, hint("Radios differ by more than ten dB. Walk away with the phone and watch the reading below to find the value that fits your desk.")],
            [label("Right now:"), liveLabel],
            [label("Pause:"), row([snoozeLabel, snoozeButton])],
        ])
        return configure(grid)
    }

    private func buildSafeNetworksTab() -> NSView {
        addNetworkButton.target = self
        addNetworkButton.action = #selector(addCurrentNetwork)
        removeNetworkButton.target = self
        removeNetworkButton.action = #selector(removeSelectedNetwork)
        for button in [addNetworkButton, removeNetworkButton] {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("network"))
        column.width = 390
        column.resizingMask = .autoresizingMask
        networkTable.addTableColumn(column)
        networkTable.headerView = nil
        networkTable.dataSource = self
        networkTable.delegate = self
        networkTable.rowHeight = 22
        networkTable.style = .inset
        networkTable.allowsMultipleSelection = false
        networkTable.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = networkTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 420),
            scroll.heightAnchor.constraint(equalToConstant: 132),
        ])

        networkStatusLabel.font = .systemFont(ofSize: 11)
        networkStatusLabel.textColor = .secondaryLabelColor
        networkStatusLabel.preferredMaxLayoutWidth = 420

        currentNetworkLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        currentNetworkLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            hint(
                "The Mac does not lock itself while it is on one of these networks. Everything else is "
                + "unchanged: the phone still reports its presence, Lock Now still locks, and a network "
                + "that is not on the list is treated as somewhere the Mac should look after itself."
            ),
            scroll,
            row([addNetworkButton, removeNetworkButton]),
            networkStatusLabel,
            separator(),
            row([label("This network:"), currentNetworkLabel]),
            hint(
                "Networks are listed by the identifier macOS gives the network you have joined, which is "
                + "also the only thing compared. Its name is not shown because macOS reveals that only to "
                + "an app allowed to use your location, and nothing here needs to know where you are."
            ),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func buildPhotosTab() -> NSView {
        photosBox.target = self
        photosBox.action = #selector(togglePhotos)
        for (button, action) in [
            (photoAccessButton, #selector(grantPhotoAccess)),
            (photoApproveButton, #selector(approvePhotos)),
            (photoRemoveButton, #selector(removePhotos)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        photoAccessLabel.font = .systemFont(ofSize: 12)
        photoCountsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        photoWaitingLabel.font = .systemFont(ofSize: 12)
        photoWindowLabel.font = .systemFont(ofSize: 11)
        photoWindowLabel.textColor = .secondaryLabelColor
        photoSkippedLabel.font = .systemFont(ofSize: 11)
        photoSkippedLabel.textColor = .secondaryLabelColor
        photoSkippedLabel.preferredMaxLayoutWidth = 420

        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, photosBox],
            [NSGridCell.emptyContentView, hint(
                "The phone decides what is in range - the start date, how many days back, and how "
                + "often - because it is the side doing the looking. This Mac decides what to do "
                + "with it."
            )],
            [label("Photos access:"), row([photoAccessLabel, photoAccessButton])],
            [label("In Photos:"), photoCountsLabel],
            [label("Waiting:"), row([photoWaitingLabel, photoApproveButton, photoRemoveButton])],
            [label("This window:"), photoWindowLabel],
            [label("Not sent:"), photoSkippedLabel],
            [NSGridCell.emptyContentView, row([button("Sync photos now", #selector(syncPhotosNow))])],
            [NSGridCell.emptyContentView, hint(
                "Nothing is imported before you have seen the first report, and a large batch waits "
                + "for you too. Photos deleted on the phone are written down and removed when you press "
                + "Remove - macOS asks for a confirmation, and an alert appearing by itself twice an "
                + "hour would be worse than the wait. Removed photos go to Recently Deleted, so there "
                + "are 30 days in which to change your mind."
            )],
        ])
        return configure(grid)
    }

    @objc private func togglePhotos() {
        let enabled = photosBox.state == .on
        Settings.shared.photosEnabled = enabled
        hooks.photosEnabledChanged(enabled)
        // Asking for the permission is a user action, and this click is it.
        if enabled { hooks.requestPhotoAccess() }
        refreshAfterChange()
    }

    @objc private func grantPhotoAccess() {
        hooks.requestPhotoAccess()
    }

    @objc private func approvePhotos() {
        hooks.approvePhotos()
        refreshAfterChange()
    }

    @objc private func removePhotos() {
        hooks.removePhotos()
        refreshAfterChange()
    }

    @objc private func syncPhotosNow() {
        hooks.syncPhotosNow()
    }

    /// Called by the menu controller when the photo report changed under us.
    func refreshFromMenu() {
        guard window?.isVisible == true else { return }
        refresh()
    }

    private func refreshPhotos() {
        let report = hooks.photoReport()
        photosBox.state = Settings.shared.photosEnabled ? .on : .off
        photoAccessLabel.stringValue = hooks.photoReadiness()
        photoCountsLabel.stringValue = "\(report.imported) imported, \(report.removedByUser) removed here"
        var waiting: [String] = []
        if report.awaitingApproval > 0 {
            waiting.append("\(report.awaitingApproval) to import "
                + "(\(ByteCountFormatter.string(fromByteCount: report.awaitingBytes, countStyle: .file)))")
        }
        if report.pendingDeletions > 0 {
            waiting.append("\(report.pendingDeletions) to remove")
        }
        photoWaitingLabel.stringValue = waiting.isEmpty ? "nothing" : waiting.joined(separator: ", ")
        photoApproveButton.isHidden = report.awaitingApproval == 0
        photoRemoveButton.isHidden = report.pendingDeletions == 0

        if let refusal = report.refusal {
            photoWindowLabel.stringValue = "the phone is not describing its camera folder: \(refusal)"
        } else if let from = report.windowFrom {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            photoWindowLabel.stringValue = "photos taken since \(formatter.string(from: from))"
        } else {
            photoWindowLabel.stringValue = "nothing described yet"
        }

        photoSkippedLabel.stringValue = report.skipped.isEmpty
            ? "nothing was left out"
            : report.skipped.map {
                "\($0.name) - \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)), "
                    + Self.describe($0.reason)
            }.joined(separator: "\n")
    }

    /// The reason a photo will not be sent, in words rather than in a code.
    private static func describe(_ reason: PhotoExclusion) -> String {
        switch reason {
        case .size: return "too large for one transfer"
        case .unreadable: return "the phone could not read it"
        case .noLocation: return "its location could not be read, so it was not sent"
        case .noDate: return "no date could be established"
        }
    }

    /// Where the source lives. The About tab is the one place in the app that
    /// says it out loud, so it is written here and nowhere else.
    private static let sourceURL = "https://github.com/mwgo/MacDroidSync"

    /// The About tab: what used to be the system About panel, now the last card
    /// here because it is read once and never touched again. Every particular
    /// comes out of the bundle, so none of them can drift away from what was
    /// actually built.
    private func buildAboutTab() -> NSView {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleName"] as? String ?? "MacDroidSync"
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let copyright = info["NSHumanReadableCopyright"] as? String ?? ""

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = label(name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let versionLabel = label("Version \(version) (build \(build))")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        let names = NSStackView(views: [title, versionLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2

        // The icon is too tall to sit on a shared baseline with the text next to
        // it, which is what `row` gives; this one centres instead.
        let heading = NSStackView(views: [icon, names])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12

        let author = label("Free software by Marcin Wojas")
        author.font = .systemFont(ofSize: 12, weight: .semibold)

        // Every tab shares the widest one's width, so this text may as well use
        // the room instead of wrapping where the narrow grids need it to.
        let aboutWidth: CGFloat = 420

        let stack = NSStackView(views: [
            heading,
            hint(
                "Clipboard, files and presence between this Mac and an Android phone, over your own Wi-Fi.",
                width: aboutWidth
            ),
            separator(),
            author,
            hint(
                "MacDroidSync costs nothing, carries no advertising and sends nothing anywhere except to "
                + "the phone you paired it with.",
                width: aboutWidth
            ),
            hint("MIT Licence. \(copyright)", width: aboutWidth),
            hint(
                "The wire format, the key derivation and the cross platform test vectors are documented in "
                + "PROTOCOL.md in the source repository.",
                width: aboutWidth
            ),
            row([hint("Source:"), link(Self.sourceURL)]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Building blocks

    private func configure(_ grid: NSGridView) -> NSGridView {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// Wraps a tab body so it does not sit flush against the tab view border.
    private func pad(_ view: NSView) -> NSView {
        let container = NSView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            container.trailingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor, constant: 16),
            container.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: 16),
        ])
        return container
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return line
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hint(_ text: String, indent: CGFloat = 0, width: CGFloat = 340) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width - indent
        guard indent > 0 else { return field }
        let container = NSView()
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// A clickable address. AppKit draws and follows a `.link` attribute itself,
    /// as long as the field may be selected and may carry attributes, so this
    /// needs no target and no action of ours.
    private func link(_ address: String) -> NSTextField {
        let text = NSMutableAttributedString(
            string: address,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        if let url = URL(string: address) {
            text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    private func sized(_ field: NSTextField, width: CGFloat) -> NSTextField {
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// The numbers behind a preset, spelled out rather than hidden behind a name.
    private static func describe(_ preset: PresenceSettings) -> String {
        String(
            format: "Away below %.0f dBm, back at %.0f dBm, %.0f s average, locks after %.0f s",
            preset.awayThreshold, preset.nearThreshold, preset.window, preset.grace
        )
    }

    private func report(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!)
    }
}
