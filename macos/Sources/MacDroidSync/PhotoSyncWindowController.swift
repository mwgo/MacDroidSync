import AppKit
import MacDroidSyncCore

/// Everything this window is allowed to do, as closures.
///
/// The same arrangement as `SettingsHooks`, and for the same reason: the window
/// knows nothing about the coordinator, the importer or the server, so there is
/// exactly one place to look when asking what a button can set off.
struct PhotoSyncHooks {
    /// Everything waiting for a decision, newest question first.
    var pendingActions: () -> [PhotoPendingAction] = { [] }
    /// Carries out the picked rows. The result matters: a removal goes through
    /// a system alert the operator can dismiss.
    var synchronize: ([String]) -> PhotoActionOutcome = { _ in PhotoActionOutcome() }
    /// Irreversible. The window asks before calling this.
    var ignore: ([String]) -> Void = { _ in }
    var syncNow: () -> Void = {}
    /// Why the feature is doing nothing, when it is doing nothing.
    var status: () -> String? = { nil }
}

/// The table, with the two keys that only make sense inside this window.
///
/// Deliberately not menu items in `AppMenu`: Delete here means "ignore the
/// selection", which would be a startling thing for the key to do anywhere else.
final class PhotoActionTableView: NSTableView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDeleteKey?()            // Backspace, Forward Delete
        case 53: deselectAll(nil)               // Escape
        default: super.keyDown(with: event)
        }
    }
}

/// The one place where photo sync decisions are made.
///
/// Every row says what would happen to that file and why, because the two
/// decisions on offer are not symmetrical: Synchronise does the ordinary thing,
/// while Ignore is for good. Nothing here opens by itself - see `Notifier`.
final class PhotoSyncWindowController: NSWindowController, NSWindowDelegate,
                                       NSTableViewDataSource, NSTableViewDelegate {

    private let hooks: PhotoSyncHooks
    private let table = PhotoActionTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let syncButton = NSButton(title: "Synchronise selected", target: nil, action: nil)
    private let ignoreButton = NSButton(title: "Ignore selected…", target: nil, action: nil)
    private let syncNowButton = NSButton(title: "Sync photos now", target: nil, action: nil)

    /// What the table is showing. The data source reads this and nothing else:
    /// asking the hooks again mid-reload is how a table ends up drawing a row
    /// that has already gone.
    private var rows: [PhotoPendingAction] = []
    /// While a sheet is up, the list underneath must not move.
    private var isSheetUp = false
    private var statusResetWork: DispatchWorkItem?

    init(hooks: PhotoSyncHooks) {
        self.hooks = hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Photo Sync"
        // The app is an accessory: without this the window is deallocated on
        // close and the next click reopens nothing.
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 320)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildBody()
        window.setFrameAutosaveName("PhotoSyncWindow")
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    func present() {
        // An accessory app has to take focus for itself.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
        // So that ⌘A and the arrow keys go to the table rather than nowhere.
        window?.makeFirstResponder(table)
    }

    /// Called when something elsewhere changed the list. A no-op while the
    /// window is closed, and while a sheet is waiting for an answer.
    func refreshFromMenu() {
        guard window?.isVisible == true, !isSheetUp else { return }
        let fresh = sorted(hooks.pendingActions())
        guard fresh != rows else { return }
        apply(fresh)
    }

    func windowWillClose(_ notification: Notification) {
        statusResetWork?.cancel()
        statusResetWork = nil
        statusLabel.stringValue = ""
    }

    private func reload() {
        apply(hooks.pendingActions())
    }

    // MARK: - Building

    private func buildBody() -> NSView {
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.textColor = .secondaryLabelColor

        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        syncNowButton.bezelStyle = .rounded
        syncNowButton.controlSize = .small
        syncNowButton.font = .systemFont(ofSize: 11)

        syncButton.target = self
        syncButton.action = #selector(synchroniseSelected)
        syncButton.bezelStyle = .rounded
        syncButton.keyEquivalent = "\r"

        ignoreButton.target = self
        ignoreButton.action = #selector(ignoreSelected)
        ignoreButton.bezelStyle = .rounded
        ignoreButton.hasDestructiveAction = true
        // Return must never set off the irreversible one.
        ignoreButton.keyEquivalent = ""

        let scroll = buildTable()
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let middle = NSView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.addSubview(scroll)
        middle.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: middle.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: middle.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: middle.widthAnchor, constant: -60),
        ])

        let header = row([summaryLabel, spacer(), syncNowButton])
        let footer = row([selectionLabel, spacer(), ignoreButton, syncButton])

        let stack = NSStackView(views: [header, statusLabel, middle, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            middle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return body
    }

    private func buildTable() -> NSScrollView {
        for column in Self.columns {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            item.title = column.title
            item.width = column.width
            item.minWidth = column.minWidth
            if column.grows { item.resizingMask = .autoresizingMask }
            // Clicking a header has to do something, or it is a control that
            // lies about being one.
            item.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            table.addTableColumn(item)
        }
        table.headerView = NSTableHeaderView()
        table.style = .inset
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.autosaveName = "PhotoSyncColumns"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Photos waiting for a decision")
        table.onDeleteKey = { [weak self] in self?.ignoreSelected() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return scroll
    }

    // MARK: - The list

    /// The order to show rows in. Sorted here rather than left to the table:
    /// these are structs, and the key-value sorting `NSTableView` does by
    /// default needs objects.
    private func sorted(_ rows: [PhotoPendingAction]) -> [PhotoPendingAction] {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else {
            // The default puts what needs attention on top and keeps each kind
            // in one unbroken block, which is why there are no group rows.
            return PhotoPendingAction.sorted(rows)
        }
        let ordered: [PhotoPendingAction]
        switch key {
        case "kind":
            ordered = rows.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
        case "name":
            ordered = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "size":
            ordered = rows.sorted { $0.size < $1.size }
        case "date":
            ordered = rows.sorted { ($0.captureAt ?? 0) < ($1.captureAt ?? 0) }
        case "detail":
            ordered = rows.sorted { Self.detail(of: $0) < Self.detail(of: $1) }
        default:
            return PhotoPendingAction.sorted(rows)
        }
        return descriptor.ascending ? ordered : ordered.reversed()
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        apply(rows)
    }

    private func apply(_ fresh: [PhotoPendingAction]) {
        // By key rather than by index: when a row goes, every index after it
        // means a different file than it did a moment ago.
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].key : nil })
        rows = sorted(fresh)
        table.reloadData()
        let restored = IndexSet(rows.indices.filter { selected.contains(rows[$0].key) })
        if !restored.isEmpty {
            table.selectRowIndexes(restored, byExtendingSelection: false)
        }
        refreshChrome()
    }

    private func refreshChrome() {
        let blocker = hooks.status()
        summaryLabel.stringValue = rows.isEmpty
            ? "Nothing is waiting for a decision"
            : PhotoPendingAction.summary(of: rows).prefix(1).uppercased()
                + PhotoPendingAction.summary(of: rows).dropFirst()
        emptyLabel.stringValue = blocker
            ?? "Nothing is waiting. Photos arrive on their own; anything else waits here."
        emptyLabel.isHidden = !rows.isEmpty

        let picked = table.selectedRowIndexes.filter { rows.indices.contains($0) }
        let bytes = picked.reduce(Int64(0)) { $0 + rows[$1].size }
        selectionLabel.stringValue = picked.isEmpty
            ? (rows.isEmpty ? "" : "Nothing selected")
            : "\(picked.count) of \(rows.count) selected"
                + (bytes > 0 ? " — \(Self.bytes(bytes))" : "")

        let doable = picked.contains { rows[$0].isSynchronizable }
        syncButton.isEnabled = doable && blocker == nil
        ignoreButton.isEnabled = !picked.isEmpty
        syncButton.toolTip = picked.isEmpty || doable
            ? nil
            : "These items cannot be transferred; you can only stop being asked about them."
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let action = rows[row]
        let cell = NSTableCellView()

        if id == "kind" {
            let look = Self.appearance(action.kind)
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.word)
            image.contentTintColor = look.tint
            image.translatesAutoresizingMaskIntoConstraints = false
            let word = NSTextField(labelWithString: look.word)
            word.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(word)
            cell.textField = word
            // The word carries the meaning; the colour only repeats it.
            cell.setAccessibilityLabel("\(look.word), \(action.name)")
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 15),
                word.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                word.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                word.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let field: NSTextField
        switch id {
        case "name":
            field = NSTextField(labelWithString: action.name)
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = action.key
        case "size":
            field = NSTextField(labelWithString: action.size > 0 ? Self.bytes(action.size) : "")
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "date":
            field = NSTextField(labelWithString: Self.date(action.captureAt))
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .secondaryLabelColor
        default:
            let detail = Self.detail(of: action)
            field = NSTextField(labelWithString: detail)
            field.lineBreakMode = .byTruncatingTail
            field.textColor = .secondaryLabelColor
            field.toolTip = detail
        }
        field.translatesAutoresizingMaskIntoConstraints = false
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
        refreshChrome()
    }

    // MARK: - The two decisions

    @objc private func synchroniseSelected() {
        let keys = table.selectedRowIndexes.filter { rows.indices.contains($0) }.map { rows[$0].key }
        guard !keys.isEmpty else { return }
        let removes = table.selectedRowIndexes.contains { rows.indices.contains($0) && rows[$0].kind == .delete }
        if removes {
            // The removal alert is drawn by macOS, and an accessory app is not
            // frontmost - without this it opens behind whatever is being read.
            NSApp.activate(ignoringOtherApps: true)
        }
        let outcome = hooks.synchronize(keys)
        apply(hooks.pendingActions())
        report(outcome)
    }

    @objc private func ignoreSelected() {
        let picked = table.selectedRowIndexes.filter { rows.indices.contains($0) }
        let keys = picked.map { rows[$0].key }
        guard !keys.isEmpty, let window else { return }
        let names = picked.prefix(5).map { rows[$0].name }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ignore \(keys.count) item\(keys.count == 1 ? "" : "s")?"
        alert.informativeText = names.joined(separator: "\n")
            + (keys.count > names.count ? "\n…and \(keys.count - names.count) more" : "")
            + "\n\nIgnored items are treated as synchronised: they are never offered again, "
            + "and a pending removal is dropped so the photo stays in Photos. This cannot be undone."
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // Return picks Cancel: the irreversible button should need aiming at.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        isSheetUp = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isSheetUp = false
            guard response == .alertFirstButtonReturn else { return }
            self.hooks.ignore(keys)
            self.show(status: "\(keys.count) item\(keys.count == 1 ? "" : "s") ignored for good")
            self.apply(self.hooks.pendingActions())
        }
    }

    @objc private func syncNow() {
        hooks.syncNow()
        show(status: "Asked the phone for a fresh list")
    }

    /// Success is visible in the table itself, so only trouble gets a sheet.
    private func report(_ outcome: PhotoActionOutcome) {
        if let failure = outcome.failure {
            sheet(title: "Some items could not be synchronised", message: failure)
        } else if outcome.cancelledByUser {
            sheet(
                title: "The removal was cancelled",
                message: "Nothing left Photos. Those photos stay on the list; "
                    + "anything else you picked went through."
            )
        } else if outcome.notSent > 0 {
            sheet(
                title: "The phone could not be reached",
                message: "\(outcome.notSent) item\(outcome.notSent == 1 ? "" : "s") stayed on the list. "
                    + "They will be asked for when the phone is back."
            )
        } else {
            var parts: [String] = []
            if outcome.requested > 0 { parts.append("\(outcome.requested) asked for") }
            if outcome.deleted > 0 { parts.append("\(outcome.deleted) removed from Photos") }
            show(status: parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", "))
        }
    }

    private func sheet(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        isSheetUp = true
        alert.beginSheetModal(for: window) { [weak self] _ in self?.isSheetUp = false }
    }

    /// A line that says what just happened and then gets out of the way.
    private func show(status: String) {
        statusResetWork?.cancel()
        statusLabel.stringValue = status
        let work = DispatchWorkItem { [weak self] in self?.statusLabel.stringValue = "" }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: - Looks

    private struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let minWidth: CGFloat
        let grows: Bool
    }

    private static let columns = [
        Column(id: "kind", title: "Action", width: 100, minWidth: 90, grows: false),
        Column(id: "name", title: "Name", width: 210, minWidth: 120, grows: true),
        Column(id: "size", title: "Size", width: 75, minWidth: 60, grows: false),
        Column(id: "date", title: "Taken", width: 130, minWidth: 100, grows: false),
        Column(id: "detail", title: "Detail", width: 260, minWidth: 100, grows: true),
    ]

    /// Colour never carries the meaning on its own: every row shows a symbol and
    /// the word as well.
    private static func appearance(
        _ kind: PhotoActionKind
    ) -> (symbol: String, word: String, tint: NSColor) {
        switch kind {
        case .add: return ("arrow.down.circle.fill", "Add", .systemGreen)
        case .change: return ("arrow.triangle.2.circlepath", "Update", .systemBlue)
        // Orange rather than red: removed photos sit in Recently Deleted for
        // thirty days, so this should not shout louder than a real failure.
        case .delete: return ("trash", "Remove", .systemOrange)
        case .problem: return ("exclamationmark.triangle.fill", "Problem", .systemRed)
        }
    }

    /// Why this row is here, in one phrase: the phone's own reason when there
    /// is one, and otherwise what the action means.
    private static func detail(of action: PhotoPendingAction) -> String {
        action.issue?.summary ?? explain(action.kind)
    }

    private static func explain(_ kind: PhotoActionKind) -> String {
        switch kind {
        case .add: return "new on the phone"
        case .change: return "the phone holds a different version"
        case .delete: return "gone from the phone"
        case .problem: return "the phone will not send it"
        }
    }

    private static func date(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: Double(value) / 1000))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}
