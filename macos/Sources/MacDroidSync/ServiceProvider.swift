import AppKit
import MacDroidSyncCore

/// Backs the `Send to Android` entry that `NSServices` in Info.plist adds to the
/// Services menu (and to the Finder context menu).
///
/// This is the route that always works with an ad-hoc signature; the Share
/// extension in `Contents/PlugIns` covers the proper Share menu when macOS lets
/// it through.
final class ServiceProvider: NSObject {
    private let onFiles: ([URL]) -> Void

    init(onFiles: @escaping ([URL]) -> Void) {
        self.onFiles = onFiles
        super.init()
    }

    @objc func sendToAndroid(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            Log.error("The service was invoked without any file")
            error.pointee = "MacDroidSync did not receive any file to send." as NSString
            return
        }
        Log.info("Service invoked with \(urls.count) file(s)")
        DispatchQueue.main.async { self.onFiles(urls) }
    }
}
