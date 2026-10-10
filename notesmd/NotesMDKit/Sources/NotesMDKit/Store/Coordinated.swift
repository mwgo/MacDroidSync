import Foundation

/// File operations through `NSFileCoordinator`, so that iCloud and the other
/// processes on the Mac never see half of one.
enum Coordinated {
    static func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var outer: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &outer) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let outer { throw outer }
        return try result.get()
    }

    static func write(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var outer: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &outer) { url in
            result = Result {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }
        if let outer { throw outer }
        try result.get()
    }

    static func move(_ from: URL, to: URL) throws {
        var result: Result<Void, Error> = .success(())
        var outer: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &outer) { from, to in
            result = Result {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                coordinator.item(at: from, willMoveTo: to)
                if from.path.lowercased() == to.path.lowercased(), from.path != to.path {
                    // Only the case changes: through a name of its own, which a case-insensitive disk needs.
                    let aside = from.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                    try FileManager.default.moveItem(at: from, to: aside)
                    try FileManager.default.moveItem(at: aside, to: to)
                } else {
                    try FileManager.default.moveItem(at: from, to: to)
                }
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let outer { throw outer }
        try result.get()
    }

    static func copy(_ from: URL, to: URL) throws {
        var result: Result<Void, Error> = .success(())
        var outer: NSError?
        NSFileCoordinator().coordinate(readingItemAt: from, options: [], writingItemAt: to, options: .forReplacing, error: &outer) { from, to in
            result = Result {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        if let outer { throw outer }
        try result.get()
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var result: Result<Void, Error> = .success(())
        var outer: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &outer) { url in
            result = Result { try FileManager.default.removeItem(at: url) }
        }
        if let outer { throw outer }
        try result.get()
    }
}
