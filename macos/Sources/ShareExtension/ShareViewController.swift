import AppKit
import MacDroidSyncCore
import UniformTypeIdentifiers

/// Share extension: the "MacDroidSync" entry in the macOS Share menu.
///
/// It runs sandboxed and in its own process, so it does no networking and never
/// reads the shared files. All it does is write their paths into the shared
/// inbox (`ShareInbox`); the app picks them up and streams them to the phone.
///
/// The work happens in `loadView`, which is where the system template puts it:
/// `extensionContext` is already set and, unlike `viewDidAppear`, it is called
/// even though this extension shows no interface worth presenting.
@objc(ShareViewController)
final class ShareViewController: NSViewController {

    override func loadView() {
        // The host expects a view; a tiny one keeps the popover invisible.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        log("loadView, \(extensionContext?.inputItems.count ?? -1) input item(s)")
        handleRequest()
    }

    private func handleRequest() {
        collectFiles { urls in
            if urls.isEmpty {
                self.log("nothing shareable in the request")
            } else if ShareInbox.write(paths: urls) {
                self.log("handed over \(urls.count) file(s)")
                self.wakeTheApp()
            } else {
                self.log("could not write the request into \(ShareInbox.defaultDirectory.path)")
            }
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    /// Resolves every attachment that is a file URL. `loadItem` is asynchronous,
    /// so the results are collected before the request is completed.
    private func collectFiles(completion: @escaping ([URL]) -> Void) {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        log("\(attachments.count) attachment(s): \(attachments.map { $0.registeredTypeIdentifiers.joined(separator: ",") })")

        let fileProviders = attachments.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            completion([])
            return
        }

        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                defer { group.leave() }
                if let error {
                    self.log("could not read an attachment: \(error.localizedDescription)")
                    return
                }
                let url: URL?
                switch item {
                case let value as URL: url = value
                case let value as NSURL: url = value as URL
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let string as String: url = URL(string: string)
                default: url = nil
                }
                guard let url, url.isFileURL else {
                    self.log("attachment is not a file URL: \(String(describing: item))")
                    return
                }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { completion(urls) }
    }

    /// Best effort: if the app is not running there is nobody to read the inbox
    /// until it starts, so it is nudged awake. A sandboxed extension may be
    /// refused here, which is why the inbox is also read at every launch.
    private func wakeTheApp() {
        // …/MacDroidSync.app/Contents/PlugIns/ShareExtension.appex → the app bundle
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                self.log("could not wake the app: \(error.localizedDescription)")
            }
        }
    }

    private func log(_ message: String) {
        NSLog("MacDroidSync share: %@", message)
    }
}
