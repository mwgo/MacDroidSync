import AppKit
import MacDroidSyncCore

/// The panel that appears in the middle of the screen while the Mac is about to
/// lock itself, counting the seconds down.
///
/// It is a `nonactivatingPanel` on purpose: MacDroidSync is an accessory app, and
/// a countdown must never steal focus from whatever the user is doing. The
/// button still works without activating the app.
///
/// The panel keeps **no clock of its own**: every tick it asks for the time left,
/// which comes from the same state machine that decides on the lock. A counter
/// that could drift away from the decision would be worse than no counter.
final class LockCountdownWindow: NSObject {

    /// The user asked for the lock to be called off.
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var timer: DispatchSourceTimer?
    private var remaining: (() -> TimeInterval?)?

    private let countdownLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Showing

    func show(deviceName: String, remaining: @escaping () -> TimeInterval?) {
        self.remaining = remaining
        detailLabel.stringValue = "\(deviceName) is out of range"

        let panel = self.panel ?? makePanel()
        self.panel = panel
        update()
        centre(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        startTicking()
    }

    func hide() {
        timer?.cancel()
        timer = nil
        remaining = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: - Ticking

    /// Five times a second: the displayed second then changes the moment it
    /// really changes, without a visible stutter.
    private func startTicking() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.update() }
        timer.resume()
        self.timer = timer
    }

    private func update() {
        guard let seconds = remaining?() else {
            // The countdown is over, one way or the other.
            hide()
            return
        }
        countdownLabel.stringValue = "\(max(0, Int(seconds.rounded(.up))))"
    }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 320, height: 232)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary windows and above a full screen app, and present on
        // whichever Space the user is on.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = makeContentView(size: size)
        return panel
    }

    private func makeContentView(size: NSSize) -> NSView {
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Locking this Mac")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: size.height - 46, width: size.width, height: 22)
        blur.addSubview(title)

        // Monospaced digits: without them the number jitters as it counts down.
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 76, weight: .medium)
        countdownLabel.alignment = .center
        countdownLabel.frame = NSRect(x: 0, y: size.height - 140, width: size.width, height: 90)
        blur.addSubview(countdownLabel)

        let unit = NSTextField(labelWithString: "seconds")
        unit.font = .systemFont(ofSize: 12)
        unit.textColor = .secondaryLabelColor
        unit.alignment = .center
        unit.frame = NSRect(x: 0, y: size.height - 160, width: size.width, height: 16)
        blur.addSubview(unit)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 12, y: size.height - 182, width: size.width - 24, height: 16)
        blur.addSubview(detailLabel)

        let button = NSButton(title: "Don't lock", target: self, action: #selector(cancel))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 40, y: 20, width: size.width - 80, height: 32)
        blur.addSubview(button)

        return blur
    }

    /// The screen the user is actually looking at, which on more than one
    /// display is the one holding the pointer.
    private func centre(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }

    @objc private func cancel() {
        hide()
        onCancel?()
    }
}
