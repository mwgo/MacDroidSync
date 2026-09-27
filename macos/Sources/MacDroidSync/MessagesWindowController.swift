import AppKit
import MacDroidSyncCore

struct MessagesHooks {
    var isConnected: () -> Bool = { false }
}

/// The phone's conversations: the list on the left, one conversation on the
/// right. What is shown comes from `SmsStore` at once and is refreshed from the
/// phone behind it, see `SmsCoordinator`.
final class MessagesWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let coordinator: SmsCoordinator
    private let hooks: MessagesHooks

    private let threadTable = NSTableView()
    private let messageTable = NSTableView()
    private let messageScroll = NSScrollView()
    private let searchField = NSSearchField()
    private let footerDot = NSView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let composer = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let composerNote = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyView = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyBody = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let conversationView = NSView()

    private var threads: [SmsThread] = []
    private var rows: [MessageRow] = []
    private var selectedId: Int64?
    private var images: [String: NSImage] = [:]
    private var imageFailures: [String: String] = [:]
    private var imageQueue: [String] = []
    private var imagesInFlight: Set<String> = []
    private var statusReset: DispatchWorkItem?
    private var scrollToBottomNext = false
    private var lastLayoutWidth: CGFloat = 0

    init(coordinator: SmsCoordinator, hooks: MessagesHooks) {
        self.coordinator = coordinator
        self.hooks = hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildBody()
        window.setFrameAutosaveName("MessagesWindow")
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    /// Opens the window, on `threadId` when given (a notification was clicked).
    func present(threadId: Int64? = nil) {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let threadId { selectedId = threadId }
        reloadThreads()
        coordinator.refreshThreads()
        if let selectedId { open(selectedId) }
        updateChrome()
    }

    /// Whether a new message in `threadId` is already in front of the user.
    func isShowing(_ threadId: Int64) -> Bool {
        window?.isKeyWindow == true && NSApp.isActive && selectedId == threadId
    }

    func connectionChanged() {
        guard window?.isVisible == true else { return }
        updateChrome()
        if hooks.isConnected() {
            coordinator.refreshThreads()
            if let selectedId { coordinator.load(threadId: selectedId) }
        }
    }

    func handle(_ event: SmsCoordinator.Event) {
        guard window?.isVisible == true else { return }
        switch event {
        case .threads:
            reloadThreads()
            updateChrome()
        case .messages(let threadId):
            guard threadId == selectedId else { return }
            reloadMessages(keepPosition: true)
        case .failed(let reason):
            showStatus("Could not get messages: \(reason)")
            updateChrome()
        case .image(let partId, let data, let reason):
            imagesInFlight.remove(partId)
            if let data, let image = NSImage(data: data) {
                images[partId] = image
            } else {
                imageFailures[partId] = reason ?? "no picture"
            }
            reloadRows(showing: partId)
            pumpImages()
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusReset?.cancel()
        images.removeAll()
        imageFailures.removeAll()
        imageQueue.removeAll()
        imagesInFlight.removeAll()
    }

    func windowDidResize(_ notification: Notification) {
        relayoutMessagesIfNeeded()
    }

    // MARK: - Building

    private func buildBody() -> NSView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(buildSidebar())
        split.addArrangedSubview(buildConversation())
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.autosaveName = "MessagesSplit"
        DispatchQueue.main.async { if split.subviews[0].frame.width < 10 { split.setPosition(300, ofDividerAt: 0) } }
        return split
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        240
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        420
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    private func buildSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("thread"))
        threadTable.addTableColumn(column)
        threadTable.headerView = nil
        threadTable.style = .sourceList
        threadTable.rowHeight = 64
        threadTable.backgroundColor = .clear
        threadTable.dataSource = self
        threadTable.delegate = self
        threadTable.setAccessibilityLabel("Conversations")

        let scroll = NSScrollView()
        scroll.documentView = threadTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footerDot.wantsLayer = true
        footerDot.layer?.cornerRadius = 4
        footerDot.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [footerDot, footerLabel])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        [searchField, scroll, rule, footer].forEach(sidebar.addSubview)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            rule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            footerDot.widthAnchor.constraint(equalToConstant: 8),
            footerDot.heightAnchor.constraint(equalToConstant: 8),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        return sidebar
    }

    private func buildConversation() -> NSView {
        let content = NSView()

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [nameLabel, detailLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh from phone")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.isBordered = false
        refreshButton.toolTip = "Refresh from phone"
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        let header = NSStackView(views: [titles, NSView(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerRule = NSBox()
        headerRule.boxType = .separator
        headerRule.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("message"))
        messageTable.addTableColumn(column)
        messageTable.headerView = nil
        messageTable.selectionHighlightStyle = .none
        messageTable.intercellSpacing = .zero
        messageTable.backgroundColor = .textBackgroundColor
        messageTable.style = .plain
        messageTable.dataSource = self
        messageTable.delegate = self
        messageTable.setAccessibilityLabel("Messages")
        messageScroll.documentView = messageTable
        messageScroll.hasVerticalScroller = true
        messageScroll.drawsBackground = true
        messageScroll.backgroundColor = .textBackgroundColor
        messageScroll.translatesAutoresizingMaskIntoConstraints = false

        composer.placeholderString = "Text message"
        composer.font = .systemFont(ofSize: 13)
        composer.bezelStyle = .roundedBezel
        composer.target = self
        composer.action = #selector(send)
        composer.setAccessibilityLabel("Message")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = ""
        sendButton.target = self
        sendButton.action = #selector(send)
        let composerRow = NSStackView(views: [composer, sendButton])
        composerRow.orientation = .horizontal
        composerRow.spacing = 8
        composerNote.font = .systemFont(ofSize: 11)
        composerNote.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let bottom = NSStackView(views: [composerRow, composerNote, statusLabel])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 4
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        bottomRule.translatesAutoresizingMaskIntoConstraints = false

        conversationView.translatesAutoresizingMaskIntoConstraints = false
        [header, headerRule, messageScroll, bottomRule, bottom].forEach(conversationView.addSubview)

        emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize: 13)
        emptyBody.textColor = .secondaryLabelColor
        emptyBody.alignment = .center
        emptyBody.preferredMaxLayoutWidth = 380
        emptyButton.bezelStyle = .rounded
        emptyButton.target = self
        emptyButton.action = #selector(refresh)
        let icon = NSImageView(image: NSImage(systemSymbolName: "message", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        [icon, emptyTitle, emptyBody, emptyButton].forEach(emptyView.addArrangedSubview)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 10
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        [conversationView, emptyView].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            conversationView.topAnchor.constraint(equalTo: content.topAnchor),
            conversationView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            conversationView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            conversationView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            header.topAnchor.constraint(equalTo: conversationView.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            bottomRule.topAnchor.constraint(equalTo: messageScroll.bottomAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: bottomRule.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: conversationView.bottomAnchor),
            composerRow.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -16),

            emptyView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])
        return content
    }

    // MARK: - Conversations

    private func reloadThreads() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = coordinator.store.threads
        threads = query.isEmpty ? all : all.filter { matches($0, query) }
        threadTable.reloadData()
        if let selectedId, let index = threads.firstIndex(where: { $0.id == selectedId }) {
            threadTable.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateConversation()
    }

    private func matches(_ thread: SmsThread, _ query: String) -> Bool {
        if thread.title.lowercased().contains(query) { return true }
        let digits = query.filter(\.isNumber)
        if !digits.isEmpty, thread.addresses.contains(where: { $0.filter(\.isNumber).contains(digits) }) { return true }
        if thread.snippet?.lowercased().contains(query) == true { return true }
        return coordinator.store.messages(in: thread.id).contains { $0.text?.lowercased().contains(query) == true }
    }

    @objc private func searchChanged() {
        reloadThreads()
    }

    private func open(_ threadId: Int64) {
        selectedId = threadId
        coordinator.markSeen(threadId)
        scrollToBottomNext = true
        reloadMessages(keepPosition: false)
        coordinator.load(threadId: threadId)
        composer.stringValue = ""
        updateConversation()
        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threadTable.reloadData(forRowIndexes: [index], columnIndexes: [0])
        }
    }

    // MARK: - One conversation

    private func reloadMessages(keepPosition: Bool) {
        guard let selectedId else {
            rows = []
            messageTable.reloadData()
            return
        }
        let messages = coordinator.messages(in: selectedId)
        var fresh: [MessageRow] = []
        if coordinator.store.hasOlder(in: selectedId), !messages.isEmpty {
            fresh.append(.loadEarlier)
        }
        let group = coordinator.store.thread(selectedId).map { $0.addresses.count > 1 } ?? false
        for row in SmsLayout.rows(for: messages) {
            switch row {
            case .day(let label):
                fresh.append(.day(label))
            case .message(let message, let grouped, let meta):
                fresh.append(.message(MessageBubble(message: message, grouped: grouped, meta: meta, showsSender: group && !message.fromMe && !grouped)))
            }
        }
        let wasAtBottom = isScrolledToBottom
        let distanceFromBottom = messageTable.bounds.height - messageScroll.contentView.bounds.maxY
        rows = fresh
        lastLayoutWidth = messageTable.bounds.width
        messageTable.reloadData()
        messageTable.layoutSubtreeIfNeeded()
        if scrollToBottomNext || wasAtBottom || !keepPosition {
            scrollToBottomNext = false
            messageTable.scrollRowToVisible(rows.count - 1)
        } else {
            let y = max(0, messageTable.bounds.height - distanceFromBottom - messageScroll.contentView.bounds.height)
            messageScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            messageScroll.reflectScrolledClipView(messageScroll.contentView)
        }
        updateConversation()
    }

    private var isScrolledToBottom: Bool {
        messageScroll.contentView.bounds.maxY >= messageTable.bounds.height - 8
    }

    private func relayoutMessagesIfNeeded() {
        let width = messageTable.bounds.width
        guard abs(width - lastLayoutWidth) > 1, !rows.isEmpty else { return }
        lastLayoutWidth = width
        messageTable.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private func reloadRows(showing partId: String) {
        let indexes = rows.indices.filter { index in
            if case .message(let bubble) = rows[index] {
                return bubble.message.images?.contains { $0.partId == partId } == true
            }
            return false
        }
        guard !indexes.isEmpty else { return }
        let wasAtBottom = isScrolledToBottom
        messageTable.noteHeightOfRows(withIndexesChanged: IndexSet(indexes))
        messageTable.reloadData(forRowIndexes: IndexSet(indexes), columnIndexes: [0])
        if wasAtBottom { messageTable.scrollRowToVisible(rows.count - 1) }
    }

    private func updateConversation() {
        let thread = selectedId.flatMap { coordinator.store.thread($0) }
        let connected = hooks.isConnected()
        nameLabel.stringValue = thread?.title ?? ""
        if let thread {
            if thread.addresses.count > 1 {
                detailLabel.stringValue = "\(thread.addresses.count) people"
            } else if thread.name != nil {
                detailLabel.stringValue = thread.addresses.first ?? ""
            } else {
                detailLabel.stringValue = thread.canReply ? "Not in contacts" : "Sender ID · replies not possible"
            }
        } else {
            detailLabel.stringValue = ""
        }
        let canWrite = thread?.canReply == true && connected
        composer.isEnabled = canWrite
        sendButton.isEnabled = canWrite
        if thread == nil {
            composerNote.stringValue = ""
        } else if !connected {
            composerNote.stringValue = "The phone is not connected; showing stored messages."
        } else if thread?.canReply == false {
            composerNote.stringValue = thread!.addresses.count > 1
                ? "Replies to group conversations are not supported yet."
                : "This sender does not accept replies."
        } else {
            composerNote.stringValue = ""
        }
        composerNote.isHidden = composerNote.stringValue.isEmpty
        refreshButton.isEnabled = connected
        conversationView.isHidden = thread == nil
        updateEmptyState()
    }

    private func updateEmptyState() {
        let connected = hooks.isConnected()
        emptyView.isHidden = selectedId.flatMap { coordinator.store.thread($0) } != nil
        emptyButton.isHidden = true
        if let refusal = coordinator.refusal, coordinator.store.threads.isEmpty {
            emptyTitle.stringValue = "Allow access to messages on the phone"
            emptyBody.stringValue = "\(refusal.prefix(1).uppercased() + refusal.dropFirst()). Grant it in MacDroidSync's settings on the phone."
            emptyButton.isHidden = !connected
        } else if coordinator.store.threads.isEmpty && !connected {
            emptyTitle.stringValue = "Phone not connected"
            emptyBody.stringValue = "Messages are read from the phone while it is connected. Open MacDroidSync on the phone, or check that both devices are on the same network."
        } else if coordinator.store.threads.isEmpty {
            emptyTitle.stringValue = "No conversations"
            emptyBody.stringValue = "Nothing has been received from the phone yet."
            emptyButton.isHidden = false
        } else {
            emptyTitle.stringValue = "No conversation selected"
            emptyBody.stringValue = "Choose a conversation on the left."
        }
    }

    private func updateChrome() {
        let connected = hooks.isConnected()
        footerDot.layer?.backgroundColor = (connected ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        if connected {
            if let sync = coordinator.lastSync {
                let time = DateFormatter.localizedString(from: sync, dateStyle: .none, timeStyle: .short)
                footerLabel.stringValue = "Phone connected · synced \(time)"
            } else {
                footerLabel.stringValue = "Phone connected"
            }
        } else {
            footerLabel.stringValue = "Phone not connected · stored messages"
        }
        updateConversation()
    }

    private func showStatus(_ text: String) {
        statusReset?.cancel()
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        let reset = DispatchWorkItem { [weak self] in
            self?.statusLabel.stringValue = ""
            self?.statusLabel.isHidden = true
        }
        statusReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: reset)
    }

    // MARK: - Actions

    @objc private func refresh() {
        guard coordinator.refreshThreads() else {
            showStatus("The phone is not connected.")
            updateChrome()
            return
        }
        if let selectedId { coordinator.load(threadId: selectedId) }
    }

    @objc private func send() {
        guard let selectedId, let thread = coordinator.store.thread(selectedId) else { return }
        let text = composer.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if coordinator.send(text, to: thread) {
            composer.stringValue = ""
            scrollToBottomNext = true
        } else {
            showStatus("Not sent: the phone is not connected.")
        }
    }

    @objc private func loadEarlier() {
        guard let selectedId else { return }
        if !coordinator.load(threadId: selectedId, older: true) {
            showStatus("The phone is not connected.")
        }
    }

    @objc private func showImage(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view as? NSImageView, let image = view.image, images.values.contains(where: { $0 === image }) else { return }
        let size = MessageRowView.fit(image.size, into: NSSize(width: 640, height: 640))
        let viewer = NSImageView(frame: NSRect(origin: .zero, size: size))
        viewer.image = image
        viewer.imageScaling = .scaleProportionallyUpOrDown
        let controller = NSViewController()
        controller.view = viewer
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    // MARK: - Pictures

    private func wantImage(_ partId: String) {
        guard images[partId] == nil, imageFailures[partId] == nil,
              !imagesInFlight.contains(partId), !imageQueue.contains(partId) else { return }
        if let data = coordinator.store.image(partId: partId), let image = NSImage(data: data) {
            images[partId] = image
            return
        }
        imageQueue.append(partId)
        pumpImages()
    }

    /// Two at a time: the phone decodes each picture, and a long conversation
    /// scrolled quickly would otherwise ask for dozens at once.
    private func pumpImages() {
        while imagesInFlight.count < 2, !imageQueue.isEmpty {
            let partId = imageQueue.removeLast()
            imagesInFlight.insert(partId)
            if !coordinator.requestImage(partId: partId) {
                imagesInFlight.remove(partId)
                imageFailures[partId] = "the phone is not connected"
                imageQueue.removeAll()
                reloadRows(showing: partId)
            }
        }
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === threadTable ? threads.count : rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === messageTable else { return 64 }
        switch rows[row] {
        case .loadEarlier: return 40
        case .day: return 34
        case .message(let bubble):
            return MessageRowView.height(for: bubble, width: messageTable.bounds.width, images: images)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === threadTable {
            let cell = ThreadCellView()
            cell.configure(threads[row], unread: coordinator.isUnread(threads[row]))
            return cell
        }
        switch rows[row] {
        case .loadEarlier:
            let button = NSButton(title: "Load earlier messages", target: self, action: #selector(loadEarlier))
            button.bezelStyle = .rounded
            button.controlSize = .small
            let holder = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            return holder
        case .day(let label):
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.alignment = .center
            text.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.addSubview(text)
            NSLayoutConstraint.activate([
                text.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                text.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            ])
            return holder
        case .message(let bubble):
            let view = MessageRowView(bubble: bubble)
            view.senderName = bubble.showsSender ? bubble.message.address : nil
            for part in bubble.message.images ?? [] {
                if let image = images[part.partId] {
                    view.images[part.partId] = image
                } else if let failure = imageFailures[part.partId] {
                    view.imageNotes[part.partId] = failure
                } else {
                    wantImage(part.partId)
                    if let image = images[part.partId] { view.images[part.partId] = image }
                }
            }
            view.onImageClick = { [weak self] recognizer in self?.showImage(recognizer) }
            view.rebuild()
            return view
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === threadTable else { return }
        let row = threadTable.selectedRow
        guard row >= 0, row < threads.count, threads[row].id != selectedId else { return }
        open(threads[row].id)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === threadTable
    }
}

// MARK: - Rows

struct MessageBubble {
    let message: SmsMessage
    let grouped: Bool
    let meta: String?
    let showsSender: Bool
}

enum MessageRow {
    case loadEarlier
    case day(String)
    case message(MessageBubble)
}

/// One conversation in the list: avatar, name, time, two lines of the latest
/// message and a dot when something is unread.
final class ThreadCellView: NSTableCellView {
    private let avatar = NSView()
    private let initials = NSTextField(labelWithString: "")
    private let person = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 19
        initials.font = .systemFont(ofSize: 14, weight: .semibold)
        initials.textColor = .white
        initials.alignment = .center
        person.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        person.contentTintColor = .white
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        snippet.font = .systemFont(ofSize: 12)
        snippet.textColor = .secondaryLabelColor
        snippet.maximumNumberOfLines = 2
        snippet.lineBreakMode = .byTruncatingTail
        snippet.cell?.truncatesLastVisibleLine = true
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        for view in [avatar, initials, person, name, time, snippet, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        avatar.addSubview(initials)
        avatar.addSubview(person)
        [avatar, name, time, snippet, dot].forEach(addSubview)
        textField = name
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            avatar.widthAnchor.constraint(equalToConstant: 38),
            avatar.heightAnchor.constraint(equalToConstant: 38),
            initials.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            person.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            person.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            snippet.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            snippet.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            snippet.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.topAnchor.constraint(equalTo: snippet.topAnchor, constant: 4),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ thread: SmsThread, unread: Bool) {
        name.stringValue = thread.title
        name.font = .systemFont(ofSize: 13, weight: unread ? .bold : .semibold)
        time.stringValue = SmsLayout.listTime(for: Date(timeIntervalSince1970: TimeInterval(thread.date) / 1000))
        let text = thread.snippet ?? ""
        snippet.stringValue = thread.lastFromMe == true ? "You: \(text)" : text
        dot.isHidden = !unread
        let letters = SmsRules.initials(of: thread)
        initials.stringValue = letters ?? ""
        initials.isHidden = letters == nil
        person.isHidden = letters != nil
        avatar.layer?.backgroundColor = Self.color(for: thread).cgColor
        setAccessibilityLabel("\(thread.title), \(time.stringValue), \(snippet.stringValue)\(unread ? ", unread" : "")")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            time.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            snippet.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            dot.layer?.backgroundColor = (selected ? NSColor.white : NSColor.controlAccentColor).cgColor
        }
    }

    /// A stable colour per conversation; grey for a bare number.
    private static func color(for thread: SmsThread) -> NSColor {
        guard thread.name != nil else { return .systemGray }
        let palette: [NSColor] = [.systemOrange, .systemTeal, .systemPurple, .systemPink, .systemBlue, .systemGreen, .systemBrown, .systemIndigo]
        let index = Int(UInt64(bitPattern: thread.id) % UInt64(palette.count))
        return palette[index].blended(withFraction: 0.25, of: .black) ?? palette[index]
    }
}

/// One message: an optional sender line, pictures, the text bubble and the
/// time underneath. Laid out by hand, so the height the table asks for and the
/// layout drawn come from the same numbers.
final class MessageRowView: NSView {
    static let maxBubble: CGFloat = 440
    static let imageBox = NSSize(width: 240, height: 240)
    static let textFont = NSFont.systemFont(ofSize: 13)
    static let padH: CGFloat = 12
    static let padV: CGFloat = 7
    static let side: CGFloat = 20

    let bubble: MessageBubble
    var senderName: String?
    var images: [String: NSImage] = [:]
    var imageNotes: [String: String] = [:]
    var onImageClick: ((NSClickGestureRecognizer) -> Void)?

    private var imageViews: [NSView] = []
    private var bubbleView: NSView?
    private var textView: NSTextField?
    private var metaView: NSTextField?
    private var senderView: NSTextField?

    override var isFlipped: Bool { true }

    init(bubble: MessageBubble) {
        self.bubble = bubble
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static var incoming: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.24, alpha: 1)
                : NSColor(calibratedRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
        }
    }

    static func fit(_ size: NSSize, into box: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 220, height: 150) }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return NSSize(width: max(60, (size.width * scale).rounded()), height: max(40, (size.height * scale).rounded()))
    }

    private static func imageSize(_ part: SmsImage, loaded: NSImage?) -> NSSize {
        if let loaded { return fit(loaded.size, into: imageBox) }
        if let width = part.width, let height = part.height {
            return fit(NSSize(width: width, height: height), into: imageBox)
        }
        return NSSize(width: 220, height: 150)
    }

    private static func textSize(_ text: String, width: CGFloat) -> NSSize {
        let maxText = min(maxBubble, (width - 2 * side) * 0.7) - 2 * padH
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(60, maxText), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        return NSSize(width: ceil(rect.width) + 4, height: ceil(rect.height))
    }

    static func height(for bubble: MessageBubble, width: CGFloat, images: [String: NSImage] = [:]) -> CGFloat {
        var y: CGFloat = bubble.grouped ? 2 : 8
        if bubble.showsSender && bubble.message.address != nil { y += 16 }
        for part in bubble.message.images ?? [] {
            y += imageSize(part, loaded: images[part.partId]).height + 4
        }
        if let text = bubble.message.text, !text.isEmpty {
            y += textSize(text, width: width).height + 2 * padV
        }
        if bubble.meta != nil { y += 17 }
        return y + 2
    }

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        imageViews = []
        let message = bubble.message
        if let senderName {
            let label = NSTextField(labelWithString: senderName)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(label)
            senderView = label
        }
        for part in message.images ?? [] {
            let view: NSView
            if let image = images[part.partId] {
                let imageView = NSImageView()
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 14
                imageView.layer?.masksToBounds = true
                imageView.setAccessibilityLabel("Photo")
                imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
                view = imageView
            } else {
                let box = NSView()
                box.wantsLayer = true
                box.layer?.cornerRadius = 14
                box.layer?.backgroundColor = Self.incoming.cgColor
                let note = NSTextField(labelWithString: imageNotes[part.partId].map { "Photo unavailable: \($0)" } ?? "Photo (MMS)")
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                note.alignment = .center
                note.lineBreakMode = .byWordWrapping
                note.maximumNumberOfLines = 3
                note.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(note)
                NSLayoutConstraint.activate([
                    note.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                    note.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                    note.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -16),
                ])
                view = box
            }
            addSubview(view)
            imageViews.append(view)
        }
        if let text = message.text, !text.isEmpty {
            let bubbleView = NSView()
            bubbleView.wantsLayer = true
            bubbleView.layer?.cornerRadius = 16
            addSubview(bubbleView)
            self.bubbleView = bubbleView
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = Self.textFont
            label.isSelectable = true
            label.drawsBackground = false
            label.textColor = message.fromMe ? .white : .labelColor
            addSubview(label)
            textView = label
        }
        if let meta = bubble.meta {
            let label = NSTextField(labelWithString: meta)
            label.font = .systemFont(ofSize: 11)
            label.textColor = meta.contains("Not sent") ? .systemRed : .secondaryLabelColor
            addSubview(label)
            metaView = label
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let message = bubble.message
        let width = bounds.width
        let right = message.fromMe
        func place(_ size: NSSize, at y: CGFloat) -> NSRect {
            let x = right ? width - Self.side - size.width : Self.side
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        var y: CGFloat = bubble.grouped ? 2 : 8
        if let senderView {
            senderView.sizeToFit()
            senderView.frame = place(NSSize(width: senderView.frame.width, height: 14), at: y).offsetBy(dx: right ? -6 : 6, dy: 0)
            y += 16
        }
        for (part, view) in zip(message.images ?? [], imageViews) {
            let size = Self.imageSize(part, loaded: images[part.partId])
            view.frame = place(size, at: y)
            y += size.height + 4
        }
        if let textView, let bubbleView, let text = message.text {
            let size = Self.textSize(text, width: width)
            let frame = place(NSSize(width: size.width + 2 * Self.padH, height: size.height + 2 * Self.padV), at: y)
            bubbleView.frame = frame
            bubbleView.layer?.backgroundColor = (right ? NSColor.controlAccentColor : Self.incoming).cgColor
            textView.frame = frame.insetBy(dx: Self.padH - 2, dy: Self.padV)
            y = frame.maxY
        }
        if let metaView {
            metaView.sizeToFit()
            metaView.frame = place(NSSize(width: metaView.frame.width, height: 14), at: y + 3).offsetBy(dx: right ? -6 : 6, dy: 0)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        onImageClick?(recognizer)
    }
}
