import AppKit
import MacDroidSyncCore

struct MessagesHooks {
    var isConnected: () -> Bool = { false }
}

/// The phone's conversations: the list on the left, one conversation on the
/// right. What is shown comes from `SmsStore` at once and is refreshed from the
/// phone behind it, see `SmsCoordinator`.
///
/// Laid out after Messages on macOS 26: a glass sidebar, the conversation
/// running under a floating header and a floating composer.
final class MessagesWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSSearchFieldDelegate, NSTextFieldDelegate {

    private let coordinator: SmsCoordinator
    private let hooks: MessagesHooks

    private let threadTable = NSTableView()
    private let messageTable = NSTableView()
    private let messageScroll = NSScrollView()
    private let searchField = CapsuleSearchField()
    private let footerDot = NSView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let nameButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = NSButton()
    private let composer = NSTextField()
    private let sendButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusBubble = NSView()
    private let emptyView = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyBody = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let conversationView = ImageDropView()
    private let emojiButton = NSButton()
    private let attachButton = NSButton()
    private var attachmentBubble = NSView()
    private let attachmentPreview = NSImageView()
    private let attachmentLabel = NSTextField(labelWithString: "")
    /// The picture that goes with the next Send, already made small enough.
    private var attachment: SmsOutgoingImage?

    private var threads: [SmsThread] = []
    private var rows: [MessageRow] = []
    private var selectedId: Int64?
    private var images: [String: NSImage] = [:]
    private var imageFailures: [String: String] = [:]
    /// Contact photos by photo id, and the ids known to have none.
    private var avatars: [String: NSImage] = [:]
    private var noAvatar: Set<String> = []
    private let headerAvatar = AvatarView(diameter: 40)
    private var imageQueue: [String] = []
    private var imagesInFlight: Set<String> = []
    private var statusReset: DispatchWorkItem?
    private var scrollToBottomNext = false
    private var lastLayoutWidth: CGFloat = 0

    /// Room the floating header and composer take over the conversation.
    private static let headerInset: CGFloat = 96
    private static let composerInset: CGFloat = 64

    init(coordinator: SmsCoordinator, hooks: MessagesHooks) {
        self.coordinator = coordinator
        self.hooks = hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 460)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = buildSplit()
        window.setContentSize(NSSize(width: 1000, height: 680))
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
        window?.makeFirstResponder(threadTable)
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
        case .avatar(let photo, let data):
            if let data, let image = NSImage(data: data) {
                avatars[photo] = image
            } else {
                noAvatar.insert(photo)
            }
            let rows = threads.indices.filter { threads[$0].photo == photo }.map(tableRow(ofThread:))
            if !rows.isEmpty { threadTable.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: [0]) }
            updateConversation()
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusReset?.cancel()
        images.removeAll()
        imageFailures.removeAll()
        imageQueue.removeAll()
        imagesInFlight.removeAll()
        avatars.removeAll()
        noAvatar.removeAll()
    }

    func windowDidResize(_ notification: Notification) {
        relayoutMessagesIfNeeded()
    }

    // MARK: - Building

    private func buildSplit() -> NSSplitViewController {
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.holder(buildSidebar()))
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 420
        sidebar.canCollapse = false
        sidebar.preferredThicknessFraction = 0.32
        let content = NSSplitViewItem(viewController: Self.holder(buildConversation()))
        content.titlebarSeparatorStyle = .none
        if #available(macOS 26.0, *) {
            // The conversation runs under the glass sidebar's edge, as in Messages.
            content.automaticallyAdjustsSafeAreaInsets = true
        }
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.splitView.autosaveName = "MessagesSplitGlass"
        return split
    }

    private static func holder(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    /// Liquid Glass on macOS 26, a translucent material before it.
    static func glass(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
    }

    /// A round glass button with a symbol in it; returns the glass to place.
    private static func roundButton(_ button: NSButton, symbol: String, label: String, size: CGFloat = 36) -> NSView {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            button.topAnchor.constraint(equalTo: holder.topAnchor),
            button.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            holder.widthAnchor.constraint(equalToConstant: size),
            holder.heightAnchor.constraint(equalToConstant: size),
        ])
        let glass = glass(holder, cornerRadius: size / 2)
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    /// Content fades out under the floating header and composer, like the
    /// scroll edge of Messages.
    private static func edgeFade(top: Bool, material: NSVisualEffectView.Material = .contentBackground) -> NSView {
        let fade = NSVisualEffectView()
        fade.material = material
        fade.blendingMode = .withinWindow
        fade.state = .active
        fade.maskImage = NSImage(size: NSSize(width: 1, height: 64), flipped: false) { rect in
            let gradient = NSGradient(
                colors: [.black.withAlphaComponent(0.9), .black.withAlphaComponent(0.55), .clear],
                atLocations: [0, 0.5, 1],
                colorSpace: .deviceRGB
            )
            gradient?.draw(in: rect, angle: top ? -90 : 90)
            return true
        }
        fade.translatesAutoresizingMaskIntoConstraints = false
        return fade
    }

    /// The list runs the full height of the sidebar, under the title bar and a
    /// floating glass search capsule. Its room at the top and bottom comes from
    /// spacer rows rather than content insets: a sidebar cuts off whatever
    /// scrolls into a scroll view's insets, and the point is to see it through
    /// the glass.
    private func buildSidebar() -> NSView {
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.font = .systemFont(ofSize: 14)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchHolder = NSView()
        searchHolder.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchHolder.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchHolder.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchHolder.centerYAnchor),
            searchHolder.heightAnchor.constraint(equalToConstant: 36),
        ])
        let searchGlass = Self.glass(searchHolder, cornerRadius: 18)
        searchGlass.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("thread"))
        threadTable.addTableColumn(column)
        threadTable.headerView = nil
        threadTable.style = .inset
        threadTable.intercellSpacing = NSSize(width: 0, height: 0)
        threadTable.backgroundColor = .clear
        threadTable.dataSource = self
        threadTable.delegate = self
        threadTable.setAccessibilityLabel("Conversations")

        let scroll = NSScrollView()
        scroll.documentView = threadTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let fade = Self.edgeFade(top: true, material: .sidebar)

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
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        let footerGlass = Self.glass(footer, cornerRadius: 12)
        footerGlass.translatesAutoresizingMaskIntoConstraints = false
        let bottomFade = Self.edgeFade(top: false, material: .sidebar)

        let sidebar = NSView()
        [scroll, fade, bottomFade, searchGlass, footerGlass].forEach(sidebar.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            fade.topAnchor.constraint(equalTo: sidebar.topAnchor),
            fade.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: searchGlass.bottomAnchor, constant: 18),
            bottomFade.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            bottomFade.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: 44),
            searchGlass.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 6),
            searchGlass.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            searchGlass.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            footerGlass.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            footerGlass.widthAnchor.constraint(lessThanOrEqualTo: sidebar.widthAnchor, constant: -28),
            footerGlass.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
            footerDot.widthAnchor.constraint(equalToConstant: 8),
            footerDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return sidebar
    }

    /// Spacer rows around the conversations: under the title bar and the search
    /// capsule, and over the connection line.
    private static let listTopSpace: CGFloat = 82
    private static let listBottomSpace: CGFloat = 48

    private func tableRow(ofThread index: Int) -> Int { index + 1 }

    private func threadIndex(ofRow row: Int) -> Int? {
        let index = row - 1
        return threads.indices.contains(index) ? index : nil
    }

    private func buildConversation() -> NSView {
        let content = NSView()

        // The conversation fills the pane; header and composer float over it.
        let column = NSTableColumn(identifier: .init("message"))
        messageTable.addTableColumn(column)
        messageTable.headerView = nil
        messageTable.selectionHighlightStyle = .none
        messageTable.intercellSpacing = .zero
        messageTable.backgroundColor = .clear
        messageTable.style = .plain
        messageTable.dataSource = self
        messageTable.delegate = self
        messageTable.setAccessibilityLabel("Messages")
        messageScroll.documentView = messageTable
        messageScroll.hasVerticalScroller = true
        messageScroll.drawsBackground = true
        messageScroll.backgroundColor = .textBackgroundColor
        messageScroll.automaticallyAdjustsContentInsets = false
        messageScroll.contentInsets = NSEdgeInsets(top: Self.headerInset, left: 0, bottom: Self.composerInset, right: 0)
        messageScroll.scrollerInsets = messageScroll.contentInsets
        messageScroll.translatesAutoresizingMaskIntoConstraints = false

        // Header: the photo, and the name in a glass capsule under it.
        nameButton.isBordered = false
        nameButton.font = .systemFont(ofSize: 13, weight: .semibold)
        nameButton.contentTintColor = .labelColor
        nameButton.target = self
        nameButton.action = #selector(copyNumber)
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        let nameHolder = NSView()
        nameHolder.addSubview(nameButton)
        NSLayoutConstraint.activate([
            nameButton.leadingAnchor.constraint(equalTo: nameHolder.leadingAnchor, constant: 14),
            nameButton.trailingAnchor.constraint(equalTo: nameHolder.trailingAnchor, constant: -14),
            nameButton.centerYAnchor.constraint(equalTo: nameHolder.centerYAnchor),
            nameHolder.heightAnchor.constraint(equalToConstant: 28),
        ])
        let nameGlass = Self.glass(nameHolder, cornerRadius: 14)
        let header = NSStackView(views: [headerAvatar, nameGlass])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = -4
        header.translatesAutoresizingMaskIntoConstraints = false
        let refreshGlass = Self.roundButton(refreshButton, symbol: "arrow.clockwise", label: "Refresh from phone")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        // Composer: a round +, the capsule field, a round smiley.
        let attachGlass = Self.roundButton(attachButton, symbol: "plus", label: "Attach a picture")
        attachButton.target = self
        attachButton.action = #selector(chooseAttachment)
        let emojiGlass = Self.roundButton(emojiButton, symbol: "face.smiling", label: "Emoji & Symbols")
        emojiButton.target = self
        emojiButton.action = #selector(showEmoji)

        composer.placeholderString = "Text message"
        composer.font = .systemFont(ofSize: 14)
        composer.isBordered = false
        composer.drawsBackground = false
        composer.focusRingType = .none
        composer.delegate = self
        composer.target = self
        composer.action = #selector(send)
        composer.setAccessibilityLabel("Message")
        composer.translatesAutoresizingMaskIntoConstraints = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        sendButton.contentTintColor = .systemBlue
        sendButton.isBordered = false
        sendButton.imagePosition = .imageOnly
        sendButton.toolTip = "Send"
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.isHidden = true
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        let field = NSView()
        [composer, sendButton].forEach(field.addSubview)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 16),
            composer.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            composer.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -40),
            sendButton.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6),
            sendButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 36),
        ])
        let fieldGlass = Self.glass(field, cornerRadius: 18)
        fieldGlass.translatesAutoresizingMaskIntoConstraints = false

        // The picture waiting to go, in its own glass chip above the field.
        attachmentPreview.imageScaling = .scaleProportionallyUpOrDown
        attachmentPreview.wantsLayer = true
        attachmentPreview.layer?.cornerRadius = 8
        attachmentPreview.layer?.masksToBounds = true
        attachmentPreview.translatesAutoresizingMaskIntoConstraints = false
        attachmentLabel.font = .systemFont(ofSize: 11)
        attachmentLabel.textColor = .secondaryLabelColor
        let removeAttachment = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove the picture") ?? NSImage(),
            target: self,
            action: #selector(clearAttachment)
        )
        removeAttachment.isBordered = false
        removeAttachment.contentTintColor = .secondaryLabelColor
        let chip = NSStackView(views: [attachmentPreview, attachmentLabel, removeAttachment])
        chip.orientation = .horizontal
        chip.spacing = 8
        chip.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 10)
        attachmentBubble = Self.glass(chip, cornerRadius: 14)
        attachmentBubble.isHidden = true
        attachmentBubble.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let statusHolder = NSStackView(views: [statusLabel])
        statusHolder.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        statusBubble = Self.glass(statusHolder, cornerRadius: 12)
        statusBubble.isHidden = true
        statusBubble.translatesAutoresizingMaskIntoConstraints = false

        conversationView.onDrop = { [weak self] image, name in self?.attach(image, name: name) ?? false }
        conversationView.translatesAutoresizingMaskIntoConstraints = false
        let topFade = Self.edgeFade(top: true)
        let bottomFade = Self.edgeFade(top: false)
        [messageScroll, topFade, bottomFade, header, refreshGlass, statusBubble, attachmentBubble,
         attachGlass, fieldGlass, emojiGlass].forEach(conversationView.addSubview)

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
        let top = conversationView.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            conversationView.topAnchor.constraint(equalTo: content.topAnchor),
            conversationView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            conversationView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            conversationView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            messageScroll.topAnchor.constraint(equalTo: conversationView.topAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            messageScroll.bottomAnchor.constraint(equalTo: conversationView.bottomAnchor),

            topFade.topAnchor.constraint(equalTo: conversationView.topAnchor),
            topFade.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            topFade.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            topFade.heightAnchor.constraint(equalToConstant: Self.headerInset),
            bottomFade.bottomAnchor.constraint(equalTo: conversationView.bottomAnchor),
            bottomFade.leadingAnchor.constraint(equalTo: conversationView.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: Self.composerInset),

            header.topAnchor.constraint(equalTo: conversationView.topAnchor, constant: 10),
            header.centerXAnchor.constraint(equalTo: conversationView.safeAreaLayoutGuide.centerXAnchor),
            header.widthAnchor.constraint(lessThanOrEqualTo: conversationView.widthAnchor, constant: -140),
            refreshGlass.topAnchor.constraint(equalTo: top, constant: 10),
            refreshGlass.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor, constant: -14),

            attachGlass.leadingAnchor.constraint(equalTo: conversationView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            attachGlass.centerYAnchor.constraint(equalTo: fieldGlass.centerYAnchor),
            fieldGlass.leadingAnchor.constraint(equalTo: attachGlass.trailingAnchor, constant: 10),
            fieldGlass.trailingAnchor.constraint(equalTo: emojiGlass.leadingAnchor, constant: -10),
            fieldGlass.bottomAnchor.constraint(equalTo: conversationView.bottomAnchor, constant: -14),
            emojiGlass.trailingAnchor.constraint(equalTo: conversationView.trailingAnchor, constant: -16),
            emojiGlass.centerYAnchor.constraint(equalTo: fieldGlass.centerYAnchor),
            attachmentBubble.leadingAnchor.constraint(equalTo: fieldGlass.leadingAnchor),
            attachmentBubble.bottomAnchor.constraint(equalTo: fieldGlass.topAnchor, constant: -8),
            statusBubble.centerXAnchor.constraint(equalTo: fieldGlass.centerXAnchor),
            statusBubble.bottomAnchor.constraint(equalTo: fieldGlass.topAnchor, constant: -8),
            statusBubble.widthAnchor.constraint(lessThanOrEqualTo: fieldGlass.widthAnchor),
            attachmentPreview.widthAnchor.constraint(equalToConstant: 44),
            attachmentPreview.heightAnchor.constraint(equalToConstant: 44),

            emptyView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
        return content
    }

    /// The name capsule copies the number, which Messages shows on click.
    @objc private func copyNumber() {
        guard let selectedId, let address = coordinator.store.thread(selectedId)?.addresses.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        showStatus("Copied \(address)")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === composer else { return }
        updateSendButton()
    }

    private func updateSendButton() {
        let hasText = !composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !(composer.isEnabled && (hasText || attachment != nil))
    }

    // MARK: - Conversations

    private func reloadThreads() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = coordinator.store.threads
        threads = query.isEmpty ? all : all.filter { matches($0, query) }
        threadTable.reloadData()
        if let selectedId, let index = threads.firstIndex(where: { $0.id == selectedId }) {
            threadTable.selectRowIndexes([tableRow(ofThread: index)], byExtendingSelection: false)
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
        clearAttachment()
        updateConversation()
        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threadTable.reloadData(forRowIndexes: [tableRow(ofThread: index)], columnIndexes: [0])
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
            case .message(let message, let grouped, let endsRun, let meta):
                fresh.append(.message(MessageBubble(
                    message: message,
                    grouped: grouped,
                    endsRun: endsRun,
                    meta: meta,
                    showsSender: group && !message.fromMe && !grouped
                )))
            }
        }
        if !fresh.isEmpty { fresh.append(.spacer) }
        let wasAtBottom = isScrolledToBottom
        let distanceFromBottom = messageTable.bounds.height - messageScroll.contentView.bounds.maxY
        rows = fresh
        lastLayoutWidth = messageTable.bounds.width
        messageTable.reloadData()
        messageTable.layoutSubtreeIfNeeded()
        if scrollToBottomNext || wasAtBottom || !keepPosition {
            scrollToBottomNext = false
            scrollToBottom()
        } else {
            let y = max(-Self.headerInset, messageTable.bounds.height - distanceFromBottom - messageScroll.contentView.bounds.height)
            messageScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            messageScroll.reflectScrolledClipView(messageScroll.contentView)
        }
        updateConversation()
    }

    /// After the table has taken its new height, which it does on the next pass.
    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.messageTable.layoutSubtreeIfNeeded()
            let y = max(-Self.headerInset, self.messageTable.bounds.height - self.messageScroll.contentView.bounds.height + Self.composerInset)
            self.messageScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            self.messageScroll.reflectScrolledClipView(self.messageScroll.contentView)
        }
    }

    private var isScrolledToBottom: Bool {
        messageScroll.contentView.bounds.maxY >= messageTable.bounds.height + Self.composerInset - 8
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
        if wasAtBottom { scrollToBottom() }
    }

    private func updateConversation() {
        let thread = selectedId.flatMap { coordinator.store.thread($0) }
        let connected = hooks.isConnected()
        if let thread {
            nameButton.title = thread.title
            headerAvatar.show(thread, photo: avatar(for: thread))
            if thread.addresses.count > 1 {
                nameButton.toolTip = thread.addresses.joined(separator: ", ")
            } else if thread.canReply {
                nameButton.toolTip = "\(thread.addresses.first ?? "") · click to copy"
            } else {
                nameButton.toolTip = "Sender ID · replies not possible"
            }
        }
        let canWrite = thread?.canReply == true && connected
        composer.isEnabled = canWrite
        emojiButton.isEnabled = canWrite
        attachButton.isEnabled = canWrite
        conversationView.acceptsDrops = canWrite
        // What the field cannot do is said where the typing would go.
        if thread != nil && !connected {
            composer.placeholderString = "Phone not connected"
        } else if thread?.canReply == false {
            composer.placeholderString = thread!.addresses.count > 1
                ? "Group replies are not supported yet"
                : "This sender does not accept replies"
        } else {
            composer.placeholderString = "Text message"
        }
        updateSendButton()
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
        statusBubble.isHidden = false
        attachmentBubble.alphaValue = 0
        let reset = DispatchWorkItem { [weak self] in
            self?.statusLabel.stringValue = ""
            self?.statusBubble.isHidden = true
            self?.attachmentBubble.alphaValue = 1
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else { return }
        if coordinator.send(text, image: attachment, to: thread) {
            composer.stringValue = ""
            clearAttachment()
            updateSendButton()
            scrollToBottomNext = true
        } else {
            showStatus("Not sent: the phone is not connected.")
        }
    }

    @objc private func showEmoji() {
        window?.makeFirstResponder(composer)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func chooseAttachment() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to send"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.attach(image, name: url.lastPathComponent)
        }
    }

    @discardableResult
    private func attach(_ image: NSImage, name: String?) -> Bool {
        guard let prepared = MessageImagePreparer.prepare(image) else {
            showStatus("That picture could not be read.")
            return false
        }
        attachment = prepared
        attachmentPreview.image = image
        let size = ByteCountFormatter.string(fromByteCount: Int64(prepared.jpeg.count), countStyle: .file)
        attachmentLabel.stringValue = [name, "\(prepared.width)×\(prepared.height), \(size)"].compactMap { $0 }.joined(separator: " · ")
        attachmentBubble.isHidden = false
        updateSendButton()
        window?.makeFirstResponder(composer)
        return true
    }

    @objc private func clearAttachment() {
        attachment = nil
        attachmentPreview.image = nil
        attachmentBubble.isHidden = true
        updateSendButton()
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

    /// The photo when it is here; otherwise asks for it once and returns nil,
    /// and the row is redrawn when it arrives.
    private func avatar(for thread: SmsThread) -> NSImage? {
        guard let photo = thread.photo else { return nil }
        if let image = avatars[photo] { return image }
        guard !noAvatar.contains(photo) else { return nil }
        if let data = coordinator.store.avatar(photo: photo), let image = NSImage(data: data) {
            avatars[photo] = image
            return image
        }
        // Without a phone there is nobody to ask until the window opens again.
        if !coordinator.requestAvatar(for: thread) { noAvatar.insert(photo) }
        return nil
    }

    private func wantImage(_ partId: String) {
        guard images[partId] == nil, imageFailures[partId] == nil,
              !imagesInFlight.contains(partId), !imageQueue.contains(partId) else { return }
        if let data = coordinator.imageAtHand(partId: partId), let image = NSImage(data: data) {
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
        tableView === threadTable ? threads.count + 2 : rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === threadTable {
            if row == 0 { return Self.listTopSpace }
            return threadIndex(ofRow: row) == nil ? Self.listBottomSpace : 76
        }
        switch rows[row] {
        case .loadEarlier: return 40
        case .spacer: return 12
        case .day: return 36
        case .message(let bubble):
            return MessageRowView.height(for: bubble, width: messageTable.bounds.width, images: images)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === threadTable {
            guard let index = threadIndex(ofRow: row) else { return NSView() }
            let cell = ThreadCellView()
            cell.configure(threads[index], unread: coordinator.isUnread(threads[index]), photo: avatar(for: threads[index]))
            return cell
        }
        switch rows[row] {
        case .spacer:
            return NSView()
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
        guard let index = threadIndex(ofRow: threadTable.selectedRow), threads[index].id != selectedId else { return }
        open(threads[index].id)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === threadTable && threadIndex(ofRow: row) != nil
    }
}

// MARK: - Search

/// A search field drawn without its own bezel, for the glass capsule it sits
/// in. Without the bezel the standard cell no longer keeps the text clear of
/// the magnifier, so the three parts are placed here.
final class CapsuleSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { CapsuleSearchFieldCell.self }
        set {}
    }
}

final class CapsuleSearchFieldCell: NSSearchFieldCell {
    private static let icon: CGFloat = 16
    private static let gap: CGFloat = 6

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.midY - Self.icon / 2, width: Self.icon, height: Self.icon)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.icon, y: rect.midY - Self.icon / 2, width: Self.icon, height: Self.icon)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let lead = Self.icon + Self.gap
        let height = cellSize(forBounds: rect).height
        return NSRect(
            x: rect.minX + lead,
            y: rect.midY - height / 2,
            width: max(0, rect.width - lead - Self.icon - Self.gap),
            height: height
        )
    }

    // The editor that takes over while typing gets the same room as the text.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

// MARK: - Pictures going out

/// Makes a picture small enough to travel to the phone. The phone shrinks it
/// again to its carrier's limit, which only it knows.
enum MessageImagePreparer {
    static let maxSide: CGFloat = 1600
    static let maxBytes = 1_500_000

    static func prepare(_ image: NSImage) -> SmsOutgoingImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var side = maxSide
        while side >= 320 {
            let scale = min(1, side / CGFloat(max(cg.width, cg.height)))
            let width = max(1, Int(CGFloat(cg.width) * scale))
            let height = max(1, Int(CGFloat(cg.height) * scale))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            // JPEG has no transparency; a PNG with holes gets a white ground.
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            for quality in [0.8, 0.65] {
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   jpeg.count <= maxBytes {
                    return SmsOutgoingImage(jpeg: jpeg, width: width, height: height)
                }
            }
            side *= 0.75
        }
        return nil
    }
}

/// The conversation pane, which takes a picture dropped on it.
final class ImageDropView: NSView {
    var onDrop: ((NSImage, String?) -> Bool)?
    var acceptsDrops = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrops && image(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrops, let (image, name) = image(from: sender) else { return false }
        return onDrop?(image, name) ?? false
    }

    private func image(from sender: NSDraggingInfo) -> (NSImage, String?)? {
        let board = sender.draggingPasteboard
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL])?.first,
           let image = NSImage(contentsOf: url) {
            return (image, url.lastPathComponent)
        }
        if let image = NSImage(pasteboard: board) { return (image, nil) }
        return nil
    }
}

// MARK: - Rows

struct MessageBubble {
    let message: SmsMessage
    let grouped: Bool
    let endsRun: Bool
    let meta: String?
    let showsSender: Bool
}

enum MessageRow {
    case loadEarlier
    case spacer
    case day(String)
    case message(MessageBubble)
}

/// One conversation in the list: avatar, name, time, two lines of the latest
/// message and a dot when something is unread.
final class ThreadCellView: NSTableCellView {
    private let avatar = AvatarView(diameter: 44)
    private let separator = NSBox()
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .systemFont(ofSize: 12)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        snippet.font = .systemFont(ofSize: 13)
        snippet.textColor = .secondaryLabelColor
        snippet.maximumNumberOfLines = 2
        snippet.lineBreakMode = .byTruncatingTail
        snippet.cell?.truncatesLastVisibleLine = true
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        separator.boxType = .separator

        for view in [avatar, name, time, snippet, dot, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        [avatar, name, time, snippet, dot, separator].forEach(addSubview)
        textField = name
        // As in Messages: the unread dot left of the photo, a hairline under
        // the text, none under the selected row.
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            snippet.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            snippet.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            snippet.trailingAnchor.constraint(equalTo: time.trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: time.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ thread: SmsThread, unread: Bool, photo: NSImage?) {
        name.stringValue = thread.title
        name.font = .systemFont(ofSize: 14, weight: unread ? .bold : .semibold)
        time.stringValue = SmsLayout.listTime(for: Date(timeIntervalSince1970: TimeInterval(thread.date) / 1000))
        // The phone has no snippet for a picture sent without words.
        let text = thread.snippet ?? "Attachment"
        snippet.stringValue = thread.lastFromMe == true ? "You: \(text)" : text
        dot.isHidden = !unread
        avatar.show(thread, photo: photo)
        setAccessibilityLabel("\(thread.title), \(time.stringValue), \(snippet.stringValue)\(unread ? ", unread" : "")")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            time.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            snippet.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            dot.layer?.backgroundColor = (selected ? NSColor.white : NSColor.systemBlue).cgColor
            separator.isHidden = selected
        }
    }

}

/// A round picture: the contact's photo when there is one, else initials on a
/// colour, else a person on grey.
final class AvatarView: NSView {
    private let diameter: CGFloat
    private let initials = NSTextField(labelWithString: "")
    private let person = NSImageView()
    private let photo = NSImageView()

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
        initials.font = .systemFont(ofSize: diameter * 0.37, weight: .semibold)
        initials.textColor = .white
        initials.alignment = .center
        person.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        person.symbolConfiguration = .init(pointSize: diameter * 0.42, weight: .regular)
        person.contentTintColor = .white
        photo.imageScaling = .scaleProportionallyUpOrDown
        for view in [initials, person, photo] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            initials.centerXAnchor.constraint(equalTo: centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: centerYAnchor),
            person.centerXAnchor.constraint(equalTo: centerXAnchor),
            person.centerYAnchor.constraint(equalTo: centerYAnchor),
            photo.leadingAnchor.constraint(equalTo: leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: trailingAnchor),
            photo.topAnchor.constraint(equalTo: topAnchor),
            photo.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ thread: SmsThread, photo image: NSImage?) {
        let letters = SmsRules.initials(of: thread)
        photo.image = image
        photo.isHidden = image == nil
        initials.stringValue = letters ?? ""
        initials.isHidden = image != nil || letters == nil
        person.isHidden = image != nil || letters != nil
        layer?.backgroundColor = SmsAvatar.color(for: thread).cgColor
    }
}

/// The round picture of a conversation, shared by the list and the notification.
enum SmsAvatar {
    /// A stable colour per conversation; grey for a bare number.
    static func color(for thread: SmsThread) -> NSColor {
        guard thread.name != nil else { return .systemGray }
        let palette: [NSColor] = [.systemOrange, .systemTeal, .systemPurple, .systemPink, .systemBlue, .systemGreen, .systemBrown, .systemIndigo]
        let index = Int(UInt64(bitPattern: thread.id) % UInt64(palette.count))
        return palette[index].blended(withFraction: 0.25, of: .black) ?? palette[index]
    }

    /// The avatar with a small message bubble in its corner, as a PNG, for a
    /// notification to carry. macOS draws the app's own icon on the left of a
    /// banner whatever the app does; this is the picture on its right.
    static func notificationPNG(for thread: SmsThread, photo: NSImage? = nil, size: CGFloat = 128) -> Data? {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
            color(for: thread).setFill()
            NSBezierPath(ovalIn: circle).fill()
            if let photo {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: circle).addClip()
                photo.draw(in: circle, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else if let letters = SmsRules.initials(of: thread) {
                let font = NSFont.systemFont(ofSize: size * (letters.count > 1 ? 0.36 : 0.44), weight: .semibold)
                let text = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: NSColor.white])
                let bounds = text.size()
                text.draw(at: NSPoint(x: circle.midX - bounds.width / 2, y: circle.midY - bounds.height / 2))
            } else if let person = symbol("person.fill", pointSize: size * 0.42, color: .white) {
                person.draw(in: centred(person.size, in: circle))
            }
            let badge = NSRect(x: rect.maxX - size * 0.40, y: rect.minY, width: size * 0.40, height: size * 0.40)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: size * 0.025, dy: size * 0.025)).fill()
            if let bubble = symbol("message.fill", pointSize: size * 0.18, color: .white) {
                bubble.draw(in: centred(bubble.size, in: badge))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private static func centred(_ size: NSSize, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// One message: an optional sender line, pictures, the bubble with its tail on
/// the last of a run, and a state such as "Delivered" underneath. Laid out by
/// hand, so the height the table asks for and the layout drawn come from the
/// same numbers.
final class MessageRowView: NSView {
    static let maxBubble: CGFloat = 460
    static let imageBox = NSSize(width: 260, height: 260)
    static let textFont = NSFont.systemFont(ofSize: 14)
    static let padH: CGFloat = 13
    static let padV: CGFloat = 8
    /// From the pane's edge to the bubble, leaving room for the tail.
    static let side: CGFloat = 22

    let bubble: MessageBubble
    var senderName: String?
    var images: [String: NSImage] = [:]
    var imageNotes: [String: String] = [:]
    var onImageClick: ((NSClickGestureRecognizer) -> Void)?

    private var imageViews: [NSView] = []
    private var bubbleView: BubbleView?
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

    /// Messages' grey, a shade lighter in the dark.
    static var incoming: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
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
        let maxText = min(maxBubble, (width - 2 * side) * 0.68) - 2 * padH
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(60, maxText), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        return NSSize(width: ceil(rect.width) + 4, height: ceil(rect.height))
    }

    static func height(for bubble: MessageBubble, width: CGFloat, images: [String: NSImage] = [:]) -> CGFloat {
        var y: CGFloat = bubble.grouped ? 2 : 6
        if bubble.showsSender && bubble.message.address != nil { y += 16 }
        for part in bubble.message.images ?? [] {
            y += imageSize(part, loaded: images[part.partId]).height + 3
        }
        if let text = bubble.message.text, !text.isEmpty {
            y += textSize(text, width: width).height + 2 * padV
        }
        if bubble.meta != nil { y += 18 }
        return y + (bubble.endsRun ? 4 : 0)
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
                imageView.layer?.cornerRadius = 18
                imageView.layer?.masksToBounds = true
                imageView.setAccessibilityLabel("Photo")
                imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
                view = imageView
            } else {
                let box = BubbleView()
                box.color = Self.incoming
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
            let bubbleView = BubbleView()
            bubbleView.color = message.fromMe ? .systemBlue : Self.incoming
            bubbleView.tail = bubble.endsRun ? (message.fromMe ? .right : .left) : nil
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
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = meta == "Not sent" ? .systemRed : .secondaryLabelColor
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
        var y: CGFloat = bubble.grouped ? 2 : 6
        if let senderView {
            senderView.sizeToFit()
            senderView.frame = place(NSSize(width: senderView.frame.width, height: 14), at: y).offsetBy(dx: right ? -8 : 8, dy: 0)
            y += 16
        }
        for (part, view) in zip(message.images ?? [], imageViews) {
            let size = Self.imageSize(part, loaded: images[part.partId])
            view.frame = place(size, at: y)
            y += size.height + 3
        }
        if let textView, let bubbleView, let text = message.text {
            let size = Self.textSize(text, width: width)
            let frame = place(NSSize(width: size.width + 2 * Self.padH, height: size.height + 2 * Self.padV), at: y)
            // The tail hangs outside the bubble, so the view is wider than it.
            bubbleView.frame = frame.insetBy(dx: -BubbleView.tailWidth, dy: 0)
            textView.frame = frame.insetBy(dx: Self.padH - 2, dy: Self.padV)
            y = frame.maxY
        }
        if let metaView {
            metaView.sizeToFit()
            metaView.frame = place(NSSize(width: metaView.frame.width, height: 14), at: y + 3).offsetBy(dx: right ? -4 : 4, dy: 0)
        }
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        onImageClick?(recognizer)
    }
}

/// A message bubble, with Messages' tail at the bottom corner when it ends a run.
final class BubbleView: NSView {
    enum Tail { case left, right }

    static let tailWidth: CGFloat = 6
    static let radius: CGFloat = 18

    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var tail: Tail? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: Self.tailWidth, dy: 0)
        let radius = min(Self.radius, body.height / 2)
        color.setFill()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        guard let tail else { return }
        let path = NSBezierPath()
        let bottom = body.maxY
        switch tail {
        case .right:
            let edge = body.maxX
            path.move(to: NSPoint(x: edge - radius, y: bottom))
            path.line(to: NSPoint(x: edge + Self.tailWidth, y: bottom))
            path.curve(
                to: NSPoint(x: edge, y: bottom - radius),
                controlPoint1: NSPoint(x: edge + 1, y: bottom - 2),
                controlPoint2: NSPoint(x: edge, y: bottom - radius / 2)
            )
            path.line(to: NSPoint(x: edge - radius, y: bottom - radius))
        case .left:
            let edge = body.minX
            path.move(to: NSPoint(x: edge + radius, y: bottom))
            path.line(to: NSPoint(x: edge - Self.tailWidth, y: bottom))
            path.curve(
                to: NSPoint(x: edge, y: bottom - radius),
                controlPoint1: NSPoint(x: edge - 1, y: bottom - 2),
                controlPoint2: NSPoint(x: edge, y: bottom - radius / 2)
            )
            path.line(to: NSPoint(x: edge + radius, y: bottom - radius))
        }
        path.close()
        path.fill()
    }
}
