import Foundation

/// This Mac's copy of the phone's messages, kept so the window opens at once.
///
/// The phone stays the source of truth: every page it sends replaces what is
/// stored for the same stretch of time, so a message deleted on the phone
/// disappears here the next time that stretch is fetched. Nothing is ever
/// written the other way.
///
/// Main queue only. Files are private to the user: the folder is 0700 and every
/// file 0600, because these are other people's words.
public final class SmsStore {

    private struct ThreadFile: Codable {
        var messages: [SmsMessage]
        /// Whether the phone has older messages than the oldest one here.
        var more: Bool
    }

    private let directory: URL
    private let imageDirectory: URL
    private let imageLimit: Int
    private var threadList: [SmsThread]
    private var files: [Int64: ThreadFile] = [:]

    public init(directory: URL? = nil, imageDirectory: URL? = nil, imageLimit: Int = 200 * 1024 * 1024) {
        self.directory = directory ?? AppPaths.supportDirectory.appendingPathComponent("Messages", isDirectory: true)
        self.imageDirectory = imageDirectory ?? AppPaths.homeDirectory
            .appendingPathComponent("Library/Caches/MacDroidSync/MessageImages", isDirectory: true)
        self.imageLimit = imageLimit
        threadList = Self.read([SmsThread].self, from: self.directory.appendingPathComponent("threads.json")) ?? []
    }

    // MARK: - Conversations

    /// Newest first.
    public var threads: [SmsThread] { threadList }

    public var unreadCount: Int { threadList.reduce(0) { $0 + $1.unread } }

    public func thread(_ id: Int64) -> SmsThread? {
        threadList.first { $0.id == id }
    }

    /// The phone's full list. A conversation missing from it was deleted there,
    /// so its messages go too.
    public func replaceThreads(_ threads: [SmsThread]) {
        let kept = Set(threads.map(\.id))
        for gone in threadList.map(\.id) where !kept.contains(gone) {
            files[gone] = nil
            try? FileManager.default.removeItem(at: fileURL(gone))
        }
        threadList = threads.sorted { $0.date > $1.date }
        write(threadList, to: directory.appendingPathComponent("threads.json"))
    }

    // MARK: - Messages

    /// Oldest first.
    public func messages(in threadId: Int64) -> [SmsMessage] {
        file(threadId).messages
    }

    public func hasOlder(in threadId: Int64) -> Bool {
        file(threadId).more
    }

    /// Stores one page from the phone. `before` says which request it answers:
    /// nil for the newest page, else the page older than that moment. Whatever
    /// is stored for the stretch the page covers is replaced by it.
    public func applyPage(threadId: Int64, messages page: [SmsMessage], more: Bool, before: Int64?) {
        var stored = file(threadId)
        let page = page.sorted { $0.date < $1.date }
        if let before {
            let newer = stored.messages.filter { $0.date >= before }
            stored.messages = Self.unique(page + newer)
            stored.more = more
        } else if !more {
            stored.messages = page
            stored.more = false
        } else {
            let from = page.first?.date ?? Int64.max
            let older = stored.messages.filter { $0.date < from }
            stored.messages = Self.unique(older + page)
            stored.more = older.isEmpty ? true : stored.more
        }
        save(threadId, stored)
    }

    /// Messages that just arrived, and the conversation as it now looks.
    public func appendIncoming(thread: SmsThread, messages: [SmsMessage]) {
        var list = threadList.filter { $0.id != thread.id }
        list.append(thread)
        threadList = list.sorted { $0.date > $1.date }
        write(threadList, to: directory.appendingPathComponent("threads.json"))

        var stored = file(thread.id)
        stored.messages = Self.unique(stored.messages + messages).sorted { $0.date < $1.date }
        save(thread.id, stored)
    }

    // MARK: - Pictures

    public func image(partId: String) -> Data? {
        guard let url = imageURL(partId) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func storeImage(_ data: Data, partId: String) {
        guard let url = imageURL(partId) else { return }
        storePicture(data, at: url)
    }

    /// Contact photos, by the photo id the phone gives: a new photo is a new id,
    /// so a stored one never goes stale. They share the pictures' folder and limit.
    public func avatar(photo: String) -> Data? {
        guard let url = pictureURL("avatar-", photo) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func storeAvatar(_ data: Data, photo: String) {
        guard let url = pictureURL("avatar-", photo) else { return }
        storePicture(data, at: url)
    }

    private func storePicture(_ data: Data, at url: URL) {
        ensure(imageDirectory)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("Could not keep a message picture: \(error.localizedDescription)")
        }
        trimImages()
    }

    // MARK: - Forgetting

    /// Everything, on the user's request or when another phone is paired.
    public func removeAll() {
        threadList = []
        files = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    // MARK: - Storage

    private func file(_ threadId: Int64) -> ThreadFile {
        if let cached = files[threadId] { return cached }
        let loaded = Self.read(ThreadFile.self, from: fileURL(threadId)) ?? ThreadFile(messages: [], more: true)
        files[threadId] = loaded
        return loaded
    }

    private func save(_ threadId: Int64, _ stored: ThreadFile) {
        files[threadId] = stored
        write(stored, to: fileURL(threadId))
    }

    private func fileURL(_ threadId: Int64) -> URL {
        directory.appendingPathComponent("thread-\(threadId).json")
    }

    private func imageURL(_ partId: String) -> URL? {
        pictureURL("", partId)
    }

    /// Ids come from the phone, so only digits make it into a file name.
    private func pictureURL(_ prefix: String, _ id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
        return imageDirectory.appendingPathComponent("\(prefix)\(id).jpg")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        ensure(directory)
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("Could not save messages: \(error.localizedDescription)")
        }
    }

    private func ensure(_ folder: URL) {
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Oldest pictures go first once the folder is over its limit.
    private func trimImages() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: keys
        ) else { return }
        var entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > imageLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > imageLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            Log.error("Stored messages at \(url.lastPathComponent) are unreadable; they will be fetched again")
            return nil
        }
        return value
    }

    /// Later copies win: they are what the phone said most recently.
    private static func unique(_ messages: [SmsMessage]) -> [SmsMessage] {
        var seen: [String: Int] = [:]
        var out: [SmsMessage] = []
        for message in messages {
            if let index = seen[message.id] {
                out[index] = message
            } else {
                seen[message.id] = out.count
                out.append(message)
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}
