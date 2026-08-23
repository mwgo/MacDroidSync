import AppKit
import MacDroidSyncCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("MacDroidSync starting, device \(Settings.shared.deviceName)")
        // MDS_PHOTOS_PROBE=1 answers one question and quits: can this bundle see
        // the Photos library at all? It is the gate the photo sync stands on, and
        // it asks for the permission because that is the point of the run - which
        // is why it is a separate mode and not something a normal launch does.
        if ProcessInfo.processInfo.environment["MDS_PHOTOS_PROBE"] == "1" {
            runPhotosProbe()
            return
        }
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

    /// Step zero of the photo sync: the permission prompt, then a positive
    /// capability check. `.authorized` on its own has already been seen to mean
    /// "and the library is empty", so the counts are what the answer rests on.
    private func runPhotosProbe() {
        let library = PhotoKitLibrary()
        Log.info("Photos probe, before asking: \(library.diagnostics())")
        // The prompt is drawn by the system and an accessory app is not
        // frontmost, so it would otherwise open behind whatever you are looking at.
        NSApp.activate(ignoringOtherApps: true)
        library.requestAuthorization { readiness in
            Log.info("Photos probe, after asking: \(library.diagnostics())")
            switch readiness {
            case .ready:
                Log.info("Photos probe: PASS - the library answers, the photo sync can be built on this")
            case .blind:
                Log.error("Photos probe: FAIL - authorized but the library is invisible. "
                    + "Check the entitlement: codesign -d --entitlements - build/MacDroidSync.app")
            default:
                Log.error("Photos probe: FAIL - \(readiness.summary)")
            }
            NSApp.terminate(nil)
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon, no main window.
application.setActivationPolicy(.accessory)
application.run()
