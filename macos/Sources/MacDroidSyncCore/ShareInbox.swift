import Foundation

/// Hand off point between the Share extension and the app.
///
/// The extension runs in its own sandboxed process and must not touch the
/// network, so all it does is drop a small JSON request into a shared directory;
/// the app picks it up and queues the files. Each request is written to a
/// temporary name and renamed into place, so a reader never sees half a request.
public enum ShareInbox {
    /// Where the extension and the app meet. Injectable so the tests can use a
    /// scratch directory instead of the real one.
    public static var defaultDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("share-requests", isDirectory: true)
    }

    private struct Request: Codable {
        let paths: [String]
        let ts: Int64
    }

    @discardableResult
    public static func ensureDirectory(_ directory: URL = defaultDirectory) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Called from the extension. Returns false when nothing could be written,
    /// which is the only failure the extension can report to the user.
    @discardableResult
    public static func write(paths: [URL], in directory: URL = defaultDirectory) -> Bool {
        guard !paths.isEmpty else { return false }
        ensureDirectory(directory)
        let request = Request(paths: paths.map(\.path), ts: Message.now())
        // Microseconds, zero padded: file names sort chronologically even when two
        // shares land in the same millisecond.
        let stamp = String(format: "%016.0f", Date().timeIntervalSince1970 * 1_000_000)
        let name = "\(stamp)-\(UUID().uuidString).json"
        let temporary = directory.appendingPathComponent(name + ".writing")
        let final = directory.appendingPathComponent(name)
        do {
            try JSONEncoder().encode(request).write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: final)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            NSLog("MacDroidSync share request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Called from the app: reads every complete request and deletes it.
    public static func takeAll(in directory: URL = defaultDirectory) -> [URL] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var urls: [URL] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(Request.self, from: data)
            else {
                Log.error("Ignoring an unreadable share request: \(name)")
                continue
            }
            urls.append(contentsOf: request.paths.map { URL(fileURLWithPath: $0) })
        }
        return urls
    }

    /// Watches the directory so a share reaches a running app immediately.
    /// Returns nil when the directory cannot be opened; the app then only picks
    /// requests up on the next launch.
    public static func watch(
        _ directory: URL = defaultDirectory,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let path = ensureDirectory(directory).path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.error("Could not watch \(path)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
