import AppKit
import MacDroidSyncCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("MacDroidSync starting, device \(Settings.shared.deviceName)")
        // Never drawn - the app is an accessory - but it is what makes Cmd-C,
        // Cmd-V and Cmd-W work inside the settings window.
        AppMenu.install()
        controller = MenuBarController()
        // Make sure a pairing code exists before the first phone shows up. The
        // first keychain read can block for a moment, so keep it off the main
        // thread and out of the way of the menu bar item.
        DispatchQueue.global(qos: .utility).async {
            Log.info("Pairing code ready (\(Settings.shared.pairingCode.count) characters)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutDown()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon, no main window.
application.setActivationPolicy(.accessory)
application.run()
