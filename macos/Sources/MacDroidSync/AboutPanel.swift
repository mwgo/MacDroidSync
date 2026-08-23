import AppKit

/// The About window.
///
/// This is the system panel rather than a window of our own: it picks the icon,
/// the name and both version numbers straight out of the bundle, so those can
/// never drift away from what was actually built. The copyright line at the
/// bottom is `NSHumanReadableCopyright` in Info.plist; only the credits in the
/// middle are ours.
enum AboutPanel {

    static func show() {
        // An accessory app is not frontmost by default, and the panel would open
        // behind the window the user is looking at.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: "Clipboard, files and presence between this Mac and an Android phone, over your own Wi-Fi.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred,
            ]
        ))
        text.append(NSAttributedString(
            string: "Free software by Marcin Wojas\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centred,
            ]
        ))
        text.append(NSAttributedString(
            string: "MIT Licence",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred,
            ]
        ))
        return text
    }
}
