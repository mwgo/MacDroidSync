import AppKit

/// Maps the connection state onto the menu bar icon.
///
/// Two arrows pointing opposite ways, matching the application icon: the
/// clipboard, the files and the presence all travel both ways. The state shows
/// in the weight of the glyph - outline while nothing is connected, enclosed and
/// filled once it is - and in the alpha below, because a menu bar icon has no
/// room for a badge.
///
/// Each state names several symbols and takes the first one the system actually
/// has, so a name withdrawn by a future macOS degrades to a near neighbour
/// instead of leaving the menu bar blank.
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
