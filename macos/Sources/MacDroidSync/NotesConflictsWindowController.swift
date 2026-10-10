import AppKit
import MacDroidSyncCore
import NotesMDKit

/// Everything the conflicts window may do, as closures, like `PhotoSyncHooks`.
struct NotesConflictsHooks {
    var conflicts: () -> [NotesConflict] = { [] }
    /// The bytes of a picture the sync stored, by checksum.
    var asset: (String) -> Data? = { _ in nil }
    var dismiss: (String) -> Void = { _ in }
    /// Carries out the deletions held back as too many at once.
    var allowDeletions: () -> Void = {}
}

/// The list of what the notes sync could not settle by itself.
///
/// Every entry is already settled in the sense that nothing was lost - the
/// phone's version of a note changed on both sides lives on as a copy - so this
/// is where the operator looks at the two versions, pictures included, and
/// decides what to keep by editing the notes themselves, then dismisses it.
/// The one exception is a batch of deletions, which waits here to be allowed.
final class NotesConflictsWindowController: NSWindowController, NSWindowDelegate,
                                            NSTableViewDataSource, NSTableViewDelegate {

    private let hooks: NotesConflictsHooks
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No conflicts.")
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let phoneView = NSTextView()
    private let macView = NSTextView()
    private let phoneTitle = NSTextField(labelWithString: "On the phone")
    private let macTitle = NSTextField(labelWithString: "In Notes")
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private let allowButton = NSButton(title: "Delete them", target: nil, action: nil)
    private let notesButton = NSButton(title: "Open Notes", target: nil, action: nil)
    private var rows: [NotesConflict] = []

    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(hooks: NotesConflictsHooks) {
        self.hooks = hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Note Conflicts"
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    /// Something changed the list; a no-op while the window is closed.
    func refresh() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        rows = hooks.conflicts()
        table.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        let index = rows.firstIndex { $0.id == selected } ?? (rows.isEmpty ? nil : 0)
        if let index { table.selectRowIndexes([index], byExtendingSelection: false) }
        showSelection()
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let column = NSTableColumn(identifier: .init("conflict"))
        column.title = "Conflict"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        headline.font = .systemFont(ofSize: 13)
        headline.maximumNumberOfLines = 4
        for title in [phoneTitle, macTitle] { title.font = .boldSystemFont(ofSize: 12) }
        for view in [phoneView, macView] {
            view.isEditable = false
            view.isSelectable = true
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.drawsBackground = true
            view.backgroundColor = .textBackgroundColor
        }
        let phoneScroll = scroll(phoneView)
        let macScroll = scroll(macView)

        dismissButton.target = self
        dismissButton.action = #selector(dismissSelected)
        dismissButton.keyEquivalent = "\u{8}"
        allowButton.target = self
        allowButton.action = #selector(allowDeletions)
        allowButton.hasDestructiveAction = true
        notesButton.target = self
        notesButton.action = #selector(openNotes)

        let phoneColumn = NSStackView(views: [phoneTitle, phoneScroll])
        let macColumn = NSStackView(views: [macTitle, macScroll])
        for stack in [phoneColumn, macColumn] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
        }
        let versions = NSStackView(views: [macColumn, phoneColumn])
        versions.distribution = .fillEqually
        versions.spacing = 12
        let buttons = NSStackView(views: [notesButton, NSView(), allowButton, dismissButton])
        buttons.spacing = 8

        let detail = NSStackView(views: [headline, versions, buttons])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSView()
        left.addSubview(list)
        left.addSubview(emptyLabel)
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)

        for view in [list, emptyLabel, versions, buttons, phoneScroll, macScroll, headline, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            list.topAnchor.constraint(equalTo: left.topAnchor),
            list.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            left.widthAnchor.constraint(equalToConstant: 260),
            versions.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 14),
            versions.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            headline.widthAnchor.constraint(equalTo: versions.widthAnchor),
            phoneScroll.widthAnchor.constraint(equalTo: phoneColumn.widthAnchor),
            macScroll.widthAnchor.constraint(equalTo: macColumn.widthAnchor),
            phoneScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            macScroll.heightAnchor.constraint(equalTo: phoneScroll.heightAnchor),
        ])
        return split
    }

    private func scroll(_ text: NSTextView) -> NSScrollView {
        let view = NSScrollView()
        view.documentView = text
        view.hasVerticalScroller = true
        view.borderType = .lineBorder
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        return view
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let conflict = rows[row]
        let title = NSTextField(labelWithString: conflict.title)
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let when = Date(timeIntervalSince1970: TimeInterval(conflict.at) / 1000)
        let detail = NSTextField(labelWithString: "\(Self.kindName(conflict)) · \(Self.dates.string(from: when))")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelection()
    }

    private func showSelection() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else {
            headline.stringValue = rows.isEmpty ? "Nothing waits here: every note is the same on both sides." : ""
            phoneView.textStorage?.setAttributedString(NSAttributedString())
            macView.textStorage?.setAttributedString(NSAttributedString())
            dismissButton.isEnabled = false
            allowButton.isHidden = true
            return
        }
        let conflict = rows[row]
        headline.stringValue = Self.explain(conflict)
        phoneView.textStorage?.setAttributedString(render(conflict.phoneMarkdown))
        macView.textStorage?.setAttributedString(render(conflict.macMarkdown))
        dismissButton.isEnabled = true
        allowButton.isHidden = conflict.kind != NotesConflict.Kind.deletions
    }

    private static func kindName(_ conflict: NotesConflict) -> String {
        switch conflict.kind {
        case NotesConflict.Kind.edited: return "Changed on both sides"
        case NotesConflict.Kind.deletedOnPhone: return "Deleted on the phone"
        case NotesConflict.Kind.deletedOnMac: return "Deleted in Notes"
        case NotesConflict.Kind.deletions: return "Deletions waiting"
        default: return conflict.kind
        }
    }

    private static func explain(_ conflict: NotesConflict) -> String {
        switch conflict.kind {
        case NotesConflict.Kind.edited:
            return "The note was changed on the phone and in Notes. The version in Notes stayed the note on both sides; the phone's version was kept as \"\(conflict.copyTitle ?? "a copy")\"."
        case NotesConflict.Kind.deletedOnPhone:
            return "The note was deleted on the phone while it was changed in Notes, so it was put back on the phone."
        case NotesConflict.Kind.deletedOnMac:
            return "The note was deleted in Notes while it was changed on the phone, so it was put back into Notes."
        case NotesConflict.Kind.deletions:
            return "\(conflict.count ?? 0) notes were deleted on one side at once. That many are not deleted on the other side unasked."
        default:
            return conflict.title
        }
    }

    /// A version as text, headings larger and pictures drawn in.
    private func render(_ markdown: String?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let markdown else {
            out.append(NSAttributedString(string: "—", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            return out
        }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        for line in markdown.components(separatedBy: "\n") {
            if let image = Markdown.parseImage(line) {
                let sha = image.path.hasPrefix("asset:") ? String(image.path.dropFirst(6)) : ""
                if let data = hooks.asset(sha), let picture = NSImage(data: data) {
                    let attachment = NSTextAttachment()
                    let width = min(picture.size.width, 300)
                    picture.size = NSSize(width: width, height: picture.size.height * width / max(picture.size.width, 1))
                    attachment.image = picture
                    out.append(NSAttributedString(attachment: attachment))
                    out.append(NSAttributedString(string: "\n", attributes: body))
                } else {
                    out.append(NSAttributedString(string: "[picture]\n", attributes: body))
                }
                continue
            }
            var text = line
            var attributes = body
            if let level = line.prefix(while: { $0 == "#" }).count as Int?, level > 0, line.dropFirst(level).hasPrefix(" ") {
                text = String(line.dropFirst(level + 1))
                attributes[.font] = NSFont.boldSystemFont(ofSize: level == 1 ? 18 : level == 2 ? 15 : 13)
            } else if line.hasPrefix("- [ ] ") {
                text = "☐ " + line.dropFirst(6)
            } else if line.hasPrefix("- [x] ") {
                text = "☑ " + line.dropFirst(6)
            } else if line.hasPrefix("- ") {
                text = "• " + line.dropFirst(2)
            }
            out.append(NSAttributedString(string: Markdown.inlineText(text) + "\n", attributes: attributes))
        }
        return out
    }

    // MARK: - Actions

    @objc private func dismissSelected() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return }
        hooks.dismiss(rows[row].id)
        reload()
    }

    @objc private func allowDeletions() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete these notes on the other side too?"
        alert.informativeText = "In Notes they go to Recently Deleted, on the phone to its trash, for thirty days."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.hooks.allowDeletions()
            self?.reload()
        }
    }

    @objc private func openNotes() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
