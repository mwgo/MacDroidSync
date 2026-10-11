import CryptoKit
import Foundation

public enum LocalFolderError: LocalizedError, Equatable {
    /// The file is not what the sync last saw: something wrote it meanwhile.
    case changed(String)
    case missing(String)
    case notEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .changed(let path): return "\(path) changed meanwhile"
        case .missing(let path): return "\(path) is not there"
        case .notEmpty(let path): return "\(path) is not empty"
        }
    }
}

/// The Mac's side of a pair: a local folder or one on iCloud Drive. Every read
/// and write is coordinated, so that iCloud and the apps presenting the folder,
/// Notes MD among them, hear of it and never see half a file.
///
/// Its methods block; the coordinator calls them off the main thread.
public final class LocalFolder: @unchecked Sendable {

    public struct Scan {
        public var entries: [FolderEntry] = []
        /// Keys of files left alone for now: still on their way from iCloud,
        /// written a moment ago, or too large.
        public var pending: Set<String> = []
        public var tooBig: [String] = []
        public var hashes: [String: FolderSyncStore.CachedHash] = [:]
        /// The folder itself is gone or cannot be read.
        public var missing = false
        public var isUbiquitous = false
    }

    public let root: URL
    /// Files written more recently than this are left for the next cycle.
    public let settleWrites: TimeInterval
    /// Deleted files go to the Trash; without it, for the tests, they are removed.
    public let useTrash: Bool

    public init(root: URL, settleWrites: TimeInterval = 3, useTrash: Bool = true) {
        self.root = root.standardizedFileURL
        self.settleWrites = settleWrites
        self.useTrash = useTrash
    }

    // MARK: - Looking

    public func scan(cache: [String: FolderSyncStore.CachedHash], now: Date = Date()) -> Scan {
        var scan = Scan()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              fm.isReadableFile(atPath: root.path) else {
            scan.missing = true
            return scan
        }
        scan.isUbiquitous = fm.isUbiquitousItem(at: root)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        // Paths relative to the root, whatever links lead to it.
        guard let walker = fm.enumerator(atPath: root.path) else {
            scan.missing = true
            return scan
        }
        while let relative = walker.nextObject() as? String {
            let url = root.appendingPathComponent(relative)
            let name = url.lastPathComponent
            var path = relative.precomposedStringWithCanonicalMapping
            if FolderRules.isExcluded(name: name) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            // A file iCloud has not brought down yet: `.Name.icloud` in its place.
            if name.hasPrefix("."), name.hasSuffix(".icloud"), values?.isDirectory != true {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                let parent = (path as NSString).deletingLastPathComponent
                path = parent.isEmpty ? real : parent + "/" + real
                scan.pending.insert(FolderRules.key(path))
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard FolderRules.isValid(path: path) else { continue }
            let modified = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
            if values?.isDirectory == true {
                scan.entries.append(FolderEntry(p: path, m: modified, d: true))
                continue
            }
            let key = FolderRules.key(path)
            let size = Int64(values?.fileSize ?? 0)
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                scan.pending.insert(key)
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            if size > FolderRules.maxFileSize {
                scan.pending.insert(key)
                scan.tooBig.append(path)
                continue
            }
            if let date = values?.contentModificationDate, now.timeIntervalSince(date) < settleWrites {
                scan.pending.insert(key)
                continue
            }
            let sha: String
            if let cached = cache[key], cached.size == size, cached.modified == modified {
                sha = cached.sha
            } else if let computed = try? hash(url) {
                sha = computed
            } else {
                scan.pending.insert(key)
                continue
            }
            scan.hashes[key] = FolderSyncStore.CachedHash(size: size, modified: modified, sha: sha)
            scan.entries.append(FolderEntry(p: path, s: size, m: modified, h: sha))
        }
        return scan
    }

    // MARK: - Reading

    /// A copy of the file as it is now, taken under coordination so that it is
    /// whole, with its checksum. The caller removes the copy.
    public func snapshot(_ path: String, into copy: URL) throws -> String {
        let url = self.url(path)
        try coordinate(reading: url) { url in
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
        }
        return try hash(copy)
    }

    // MARK: - Writing

    /// Puts a file in place of `path`. `expected` is what is there now as the
    /// sync last saw it, nil for nothing at all; anything else and nothing is written.
    public func install(_ file: URL, at path: String, expected: String?) throws {
        let url = self.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinate(writing: url) { url in
            try self.check(url, path: path, expected: expected)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: url)
            }
        }
    }

    /// Moves a file to the Trash, if it is still what the sync last saw.
    public func delete(_ path: String, expected: String) throws {
        let url = self.url(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try coordinate(deleting: url) { url in
            try self.check(url, path: path, expected: expected)
            try self.discard(url)
        }
    }

    public func move(_ from: String, to: String, expected: String) throws {
        let source = url(from)
        let target = url(to)
        guard FileManager.default.fileExists(atPath: source.path) else { throw LocalFolderError.missing(from) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error
        ) { source, target in
            do {
                try self.check(source, path: from, expected: expected)
                let sameFile = FolderRules.key(from) == FolderRules.key(to)
                if !sameFile && FileManager.default.fileExists(atPath: target.path) {
                    throw LocalFolderError.changed(to)
                }
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if let error { throw error }
    }

    public func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    /// Removes a folder left empty, the Finder's own files apart.
    public func removeDirectory(_ path: String) throws {
        let url = self.url(path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.allSatisfy({ FolderRules.isExcluded(name: $0) && $0 != FolderRules.phoneDirectory }) else {
            throw LocalFolderError.notEmpty(path)
        }
        try coordinate(deleting: url) { url in
            try self.discard(url)
        }
    }

    // MARK: - Helpers

    private func discard(_ url: URL) throws {
        if useTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    private func check(_ url: URL, path: String, expected: String?) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch (exists, expected) {
        case (false, nil): return
        case (false, .some): throw LocalFolderError.missing(path)
        case (true, nil): throw LocalFolderError.changed(path)
        case (true, let expected?): if try hash(url) != expected { throw LocalFolderError.changed(path) }
        }
    }

    public func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let error { throw error }
    }

    private func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let error { throw error }
    }

    private func coordinate(deleting url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let error { throw error }
    }
}
