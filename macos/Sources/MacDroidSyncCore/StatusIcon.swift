import AppKit

/// Maps the connection state onto the menu bar icon.
///
/// Two arrows pointing opposite ways, matching the application icon: the
/// clipboard, the files and the presence all travel both ways. The connection
/// state shows in the weight of the glyph - outline while nothing is connected,
/// enclosed and filled once it is - and in the alpha below.
///
/// One thing does get a badge, and only one: a dot in the corner when something
/// is waiting for a decision in the photo sync window. The distinction is that
/// the connection state is *information*, which the menu already carries, while
/// a waiting decision is a **request** - nothing will move again until it is
/// answered, and that has to be visible without opening the menu.
///
/// Each state names several symbols and takes the first one the system actually
/// has, so a name withdrawn by a future macOS degrades to a near neighbour
/// instead of leaving the menu bar blank.
public enum StatusIcon {
    public static func image(for state: PeerState, needsAttention: Bool = false) -> NSImage? {
        guard let image = symbol(for: state) else { return nil }
        if state == .error {
            image.isTemplate = false
            let red = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            ) ?? image
            return needsAttention ? badged(red, tint: .systemRed) : red
        }
        image.isTemplate = true
        return needsAttention ? badged(image, tint: nil) : image
    }

    /// Dimmed while nothing is connected, full strength otherwise - except when
    /// something is waiting, which outranks the connection state: a dot nobody
    /// can see is not a request, and the phone being away is no reason to whisper
    /// about a decision that is already overdue.
    public static func alpha(for state: PeerState, needsAttention: Bool = false) -> CGFloat {
        if needsAttention { return 1.0 }
        switch state {
        case .disconnected: return 0.55
        case .suspended: return 0.4
        default: return 1.0
        }
    }

    /// The same glyph with a dot off its bottom right corner.
    ///
    /// The canvas grows rather than the glyph shrinking, so the icon does not
    /// change size when the dot comes and goes - the menu bar has room for it,
    /// and a glyph that resized itself twice an hour would be its own
    /// distraction. The dot mostly sits *outside* the glyph, and what overlap is
    /// left is punched out with a thin transparent ring: at this size the two
    /// shapes otherwise read as one blob, and in the ordinary case they are the
    /// same colour, because the icon stays a template image so that macOS keeps
    /// tinting it for whatever is behind the bar.
    private static func badged(_ base: NSImage, tint: NSColor?) -> NSImage {
        let glyph = base.size
        guard glyph.width > 0, glyph.height > 0 else { return base }
        let diameter = glyph.width * 0.28
        let overhang = diameter * 0.55
        let gap = diameter * 0.18
        let size = NSSize(width: glyph.width + overhang, height: glyph.height + overhang)

        // Composed once into pixels rather than through a redraw-on-demand
        // image: the punch-out below depends on what is already in the buffer,
        // and that is easier to be sure of when it happens exactly once. The
        // icon is built only when the state changes, so once is cheap.
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        // The glyph sits at the top of the canvas, because the dot takes the
        // corner below it. This is drawn unflipped, so y grows upwards.
        base.draw(in: NSRect(x: 0, y: overhang, width: glyph.width, height: glyph.height))
        let dot = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)

        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -gap, dy: -gap)).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        (tint ?? .black).setFill()
        NSBezierPath(ovalIn: dot).fill()
        canvas.unlockFocus()
        canvas.isTemplate = tint == nil
        canvas.accessibilityDescription = base.accessibilityDescription
        return canvas
    }

    public static func accessibilityDescription(for state: PeerState) -> String {
        switch state {
        case .disconnected: return "MacDroidSync: waiting for the phone"
        case .connecting: return "MacDroidSync: connecting"
        case .connected: return "MacDroidSync: connected"
        case .suspended: return "MacDroidSync: suspended"
        case .transferring: return "MacDroidSync: transferring the clipboard"
        case .error: return "MacDroidSync: error"
        }
    }

    private static func symbol(for state: PeerState) -> NSImage? {
        let candidates: [String]
        switch state {
        case .disconnected, .connecting:
            candidates = ["arrow.left.arrow.right", "arrow.left.and.right", "arrow.left.arrow.right.circle"]
        case .connected:
            candidates = [
                "arrow.left.arrow.right.circle.fill",
                "arrow.left.arrow.right.square.fill",
                "arrow.left.arrow.right",
            ]
        // Deliberately a different glyph rather than a different weight: the
        // transfer only shows as a flash of a few tenths of a second, and a
        // change too subtle to notice would be no signal at all.
        case .transferring:
            candidates = [
                "arrow.triangle.2.circlepath.circle.fill",
                "arrow.triangle.2.circlepath",
                "arrow.left.arrow.right.square.fill",
            ]
        case .suspended:
            candidates = ["moon.zzz.fill", "moon.zzz", "arrow.left.arrow.right"]
        case .error:
            candidates = ["exclamationmark.triangle.fill", "arrow.left.arrow.right"]
        }
        let description = accessibilityDescription(for: state)
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }
        return nil
    }
}
