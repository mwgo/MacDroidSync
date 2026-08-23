import AppKit

/// Maps the connection state onto the menu bar icon. SF Symbols with a badge on
/// the clipboard glyph do not exist on macOS, so nearby symbols are used and the
/// icon is additionally dimmed or tinted.
public enum StatusIcon {
    public static func image(for state: PeerState) -> NSImage? {
        let image = symbol(for: state)
        if state == .error {
            image?.isTemplate = false
            return image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            ) ?? image
        }
        image?.isTemplate = true
        return image
    }

    /// Dimmed while nothing is connected, full strength otherwise.
    public static func alpha(for state: PeerState) -> CGFloat {
        switch state {
        case .disconnected: return 0.55
        case .suspended: return 0.4
        default: return 1.0
        }
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
            candidates = ["clipboard", "list.clipboard", "doc.on.clipboard"]
        case .connected:
            candidates = ["clipboard.fill", "list.clipboard.fill", "doc.on.clipboard.fill"]
        case .transferring:
            candidates = ["doc.on.clipboard.fill", "checkmark.circle.fill", "clipboard.fill"]
        case .suspended:
            candidates = ["moon.zzz.fill", "moon.zzz", "clipboard"]
        case .error:
            candidates = ["exclamationmark.triangle.fill", "clipboard"]
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
