import AppKit
import MacDroidSyncCore

/// What the Folders page may do to the running app.
struct FoldersHooks {
    var pairs: () -> [FolderPair] = { [] }
    var setPairs: ([FolderPair]) -> Void = { _ in }
    /// How the pair stands, in words.
    var status: (FolderPair) -> String = { _ in "" }
    var conflicts: (FolderPair) -> [FolderConflict] = { _ in [] }
    var syncNow: (FolderPair) -> Void = { _ in }
    var allowDeletions: (FolderPair) -> Void = { _ in }
    var dismissConflict: (FolderPair, String) -> Void = { _, _ in }
}

/// The settings page of the synced folders: the pairs in a list, the one
/// selected below it, and what its sync could not settle alone.
final class FoldersPage: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private let hooks: FoldersHooks
    private let relayout: () -> Void

    private let pairTable = NSTableView()
    private let conflictTable = NSTableView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    private let phoneField = NSTextField(string: "")
    private let macLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let enabledBox = NSButton(checkboxWithTitle: "Keep these two folders the same", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncButton = NSButton(title: "Sync now", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private let allowButton = NSButton(title: "Allow deletions", target: nil, action: nil)

    private var pairs: [FolderPair] = []
    private var conflicts: [FolderConflict] = []

    init(hooks: FoldersHooks, relayout: @escaping () -> Void) {
        self.hooks = hooks
        self.relayout = relayout
    }

    // MARK: - Building

    func build() -> NSView {
        configure(pairTable, columns: [("name", "Name", 110), ("phone", "On the phone", 150), ("mac", "On this Mac", 190)])
        configure(conflictTable, columns: [("conflict", "", 450)])
        conflictTable.headerView = nil

        for (button, action) in [
            (addButton, #selector(addPair)), (removeButton, #selector(removePair)), (chooseButton, #selector(chooseMacFolder)),
            (syncButton, #selector(syncNow)), (revealButton, #selector(reveal)), (dismissButton, #selector(dismiss)),
            (allowButton, #selector(allowDeletions)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        enabledBox.target = self
        enabledBox.action = #selector(toggleEnabled)
        for field in [nameField, phoneField] {
            field.delegate = self
            field.target = self
            field.action = #selector(applyFields)
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        phoneField.placeholderString = NotesMD.phonePath
        for label in [macLabel, statusLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        }

        let grid = NSGridView(views: [
            [label("Name:"), nameField],
            [label("On the phone:"), phoneField],
            [NSGridCell.emptyContentView, hint("A folder in the phone's shared storage, such as Documents/Notes MD. The phone asks once for access to all files.")],
            [label("On this Mac:"), row([macLabel, chooseButton])],
            [NSGridCell.emptyContentView, enabledBox],
            [label("Status:"), row([statusLabel, syncButton])],
            [label("Conflicts:"), scrolled(conflictTable, width: 450, height: 90)],
            [NSGridCell.emptyContentView, row([revealButton, dismissButton, allowButton])],
            [NSGridCell.emptyContentView, hint("Files are copied both ways. A file changed on both sides keeps the Mac's version at its name, and the phone's version is kept next to it as \"name (Android, date)\". A file deleted on one side goes to the Trash on the other; more than a fifth of the files at once wait here to be allowed.")],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let buttons = row([addButton, removeButton])
        let stack = NSStackView(views: [scrolled(pairTable, width: 470, height: 110), buttons, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Keeping up

    func refresh() {
        let selected = selectedPair?.id
        pairs = hooks.pairs()
        pairTable.reloadData()
        if let selected, let index = pairs.firstIndex(where: { $0.id == selected }) {
            pairTable.selectRowIndexes([index], byExtendingSelection: false)
        } else if !pairs.isEmpty, pairTable.selectedRow < 0 {
            pairTable.selectRowIndexes([0], byExtendingSelection: false)
        }
        refreshDetail()
    }

    private func refreshDetail() {
        let pair = selectedPair
        for control in [nameField, phoneField, chooseButton, enabledBox, syncButton] as [NSControl] {
            control.isEnabled = pair != nil
        }
        removeButton.isEnabled = pair != nil
        if nameField.currentEditor() == nil { nameField.stringValue = pair?.name ?? "" }
        if phoneField.currentEditor() == nil { phoneField.stringValue = pair?.phonePath ?? "" }
        macLabel.stringValue = pair.map { Self.short($0.macPath) } ?? ""
        enabledBox.state = pair?.enabled == true ? .on : .off
        statusLabel.stringValue = pair.map(hooks.status) ?? ""
        conflicts = pair.map(hooks.conflicts) ?? []
        conflictTable.reloadData()
        refreshConflictButtons()
    }

    private func refreshConflictButtons() {
        let conflict = selectedConflict
        revealButton.isEnabled = conflict.map { $0.kind != FolderConflict.Kind.deletions && $0.kind != FolderConflict.Kind.empty } ?? false
        dismissButton.isEnabled = conflict != nil
        allowButton.isEnabled = conflicts.contains { $0.kind == FolderConflict.Kind.deletions || $0.kind == FolderConflict.Kind.empty }
    }

    private var selectedPair: FolderPair? {
        let row = pairTable.selectedRow
        return row >= 0 && row < pairs.count ? pairs[row] : nil
    }

    private var selectedConflict: FolderConflict? {
        let row = conflictTable.selectedRow
        return row >= 0 && row < conflicts.count ? conflicts[row] : nil
    }

    private func update(_ change: (inout FolderPair) -> Void) {
        guard let index = pairTable.selectedRow >= 0 && pairTable.selectedRow < pairs.count ? pairTable.selectedRow : nil else { return }
        var pair = pairs[index]
        change(&pair)
        guard pair != pairs[index] else { return }
        pairs[index] = pair
        hooks.setPairs(pairs)
        refresh()
    }

    // MARK: - Actions

    @objc private func addPair() {
        guard let url = chooseFolder(start: nil) else { return }
        let name = url.lastPathComponent
        var pairs = hooks.pairs()
        let isNotes = url.standardizedFileURL == NotesMD.folder.standardizedFileURL
        let pair = isNotes ? NotesMD.pair(macPath: url.path) : FolderPair(name: name, phonePath: "Documents/\(name)", macPath: url.path)
        pairs.append(pair)
        hooks.setPairs(pairs)
        refresh()
        if let index = pairs.firstIndex(where: { $0.id == pair.id }) {
            pairTable.selectRowIndexes([index], byExtendingSelection: false)
        }
        relayout()
    }

    @objc private func removePair() {
        guard let pair = selectedPair, let window = pairTable.window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop syncing \(pair.name)?"
        alert.informativeText = "Both folders stay as they are; only the sync between them stops."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.hooks.setPairs(self.hooks.pairs().filter { $0.id != pair.id })
            self.pairTable.deselectAll(nil)
            self.refresh()
        }
    }

    @objc private func chooseMacFolder() {
        guard let pair = selectedPair, let url = chooseFolder(start: pair.macURL) else { return }
        update { $0.macPath = url.path }
    }

    @objc private func applyFields() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let phone = phoneField.stringValue.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        update { pair in
            if !name.isEmpty { pair.name = name }
            if FolderRules.isValid(path: phone) { pair.phonePath = phone }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyFields()
    }

    @objc private func toggleEnabled() {
        update { $0.enabled = enabledBox.state == .on }
    }

    @objc private func syncNow() {
        guard let pair = selectedPair else { return }
        hooks.syncNow(pair)
    }

    @objc private func reveal() {
        guard let pair = selectedPair, let conflict = selectedConflict else { return }
        let url = pair.macURL.appendingPathComponent(conflict.copy ?? conflict.path)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : pair.macURL.appendingPathComponent(conflict.path)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @objc private func dismiss() {
        guard let pair = selectedPair, let conflict = selectedConflict else { return }
        hooks.dismissConflict(pair, conflict.id)
        refreshDetail()
    }

    @objc private func allowDeletions() {
        guard let pair = selectedPair, let window = pairTable.window else { return }
        let alert = NSAlert()
        alert.messageText = "Allow the deletions?"
        alert.informativeText = "What was deleted on one side is moved to the Trash on the other on the next sync."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.hooks.allowDeletions(pair)
            self.refreshDetail()
        }
    }

    private func chooseFolder(start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "A folder on this Mac or on iCloud Drive, kept the same as a folder on the phone."
        panel.directoryURL = start ?? NotesMD.folder.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === pairTable ? pairs.count : conflicts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        var dimmed = false
        if tableView === pairTable {
            guard row < pairs.count else { return nil }
            let pair = pairs[row]
            dimmed = !pair.enabled
            switch tableColumn?.identifier.rawValue {
            case "name": text = pair.name
            case "phone": text = pair.phonePath
            default: text = Self.short(pair.macPath)
            }
        } else {
            guard row < conflicts.count else { return nil }
            text = Self.describe(conflicts[row])
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = dimmed ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingMiddle
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
        if (notification.object as? NSTableView) === pairTable {
            refreshDetail()
        } else {
            refreshConflictButtons()
        }
    }

    // MARK: - Helpers

    private static func describe(_ conflict: FolderConflict) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        let when = formatter.string(from: Date(timeIntervalSince1970: Double(conflict.at) / 1000))
        let what: String
        switch conflict.kind {
        case FolderConflict.Kind.edited: what = "\(conflict.path): changed on both sides, the phone's kept as \((conflict.copy ?? "") as NSString).lastPathComponent)"
        case FolderConflict.Kind.deletedOnPhone: what = "\(conflict.path): deleted on the phone but changed here, put back"
        case FolderConflict.Kind.deletedOnMac: what = "\(conflict.path): deleted here but changed on the phone, put back"
        case FolderConflict.Kind.deletions: what = "\(conflict.count ?? 0) deletions at once, waiting"
        case FolderConflict.Kind.empty: what = "\(conflict.path) is empty, nothing deleted on the other side"
        case FolderConflict.Kind.tooBig: what = "\(conflict.path): too large to sync"
        default: what = conflict.path
        }
        return "\(when)  \(what)"
    }

    private static func short(_ path: String) -> String {
        let icloud = AppPaths.homeDirectory.path + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path.hasPrefix(icloud) { return "iCloud Drive" + path.dropFirst(icloud.count) }
        return path.replacingOccurrences(of: AppPaths.homeDirectory.path, with: "~")
    }

    private func configure(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .inset
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
    }

    private func scrolled(_ table: NSTableView, width: CGFloat, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hint(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 450
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }
}
