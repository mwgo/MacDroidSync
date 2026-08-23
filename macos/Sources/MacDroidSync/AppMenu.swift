import AppKit

/// The minimal `NSApp.mainMenu` a menu bar only app still needs.
///
/// MacDroidSync is an `LSUIElement`, so this menu is never drawn: an accessory
/// app has no menu bar of its own. It is installed anyway, because `mainMenu` is
/// also what dispatches **key equivalents**. Without it the settings window
/// would be a window in which the user cannot press Cmd-V to paste a pairing
/// code, Cmd-C to copy one, or Cmd-W to get rid of the window - the standard Edit
/// commands work by being sent to the first responder, and something has to send
/// them.
///
/// The Edit and Window items carry no target on purpose: `NSApplication` then
/// resolves them against the key window's responder chain, which is exactly
/// where the field editor of a text field is.
///
/// The app menu holds nothing but Quit. Settings and About belong to the status
/// menu, where they are reachable: an accessory app with no window open cannot
/// be made active from the keyboard, so a shortcut for them here would be an
/// item that never fires.
enum AppMenu {

    static func install() {
        let main = NSMenu()
        main.addItem(makeItem(title: "MacDroidSync", submenu: appMenu()))
        main.addItem(makeItem(title: "Edit", submenu: editMenu()))
        main.addItem(makeItem(title: "Window", submenu: windowMenu()))
        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit MacDroidSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }

    private static func makeItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
