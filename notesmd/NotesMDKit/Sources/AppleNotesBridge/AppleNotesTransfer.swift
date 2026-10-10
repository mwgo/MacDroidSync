#if os(macOS)
import Foundation
import NotesMDKit

/// Notes from Notes on this Mac into the folder of notes, and the other way.
/// A one-off copy each time, not a sync: a note already on the other side,
/// the same folder and the same words, is left out.
public final class AppleNotesTransfer {
    public let library: AppleNotesLibrary
    public let store: FolderStore
    private let scratch: URL

    public struct Progress {
        public var done: Int
        public var total: Int
        public var title: String
    }

    public struct Result {
        public var copied = 0
        public var skipped = 0
        public var failed: [String] = []
    }

    public init(store: FolderStore, scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("NotesMD-transfer", isDirectory: true)) {
        self.store = store
        self.scratch = scratch
        library = AppleNotesLibrary(scratch: scratch.appendingPathComponent("bridge", isDirectory: true))
    }

    public func accounts() async throws -> [AppleNotesLibrary.Account] {
        try await library.accounts()
    }

    public func appleFolders(account: String?) async throws -> [String] {
        library.accountName = { account }
        return try await library.folders()
    }

    // MARK: - Import

    public func importNotes(account: String?, folders: Set<String>, progress: (Progress) -> Void) async throws -> Result {
        library.accountName = { account }
        let notes = try await library.list().filter { folders.contains($0.folder) }
        var snapshot = try await store.scan()
        var result = Result()
        for (index, info) in notes.enumerated() {
            progress(Progress(done: index, total: notes.count, title: info.name))
            do {
                let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let content = try await library.read(id: info.id, into: work)
                let incoming = NotesMarkup.markdown(fromHTML: content.html, title: info.name)
                let key = NotesMarkup.contentKey(incoming.markdown)
                if try await exists(key: key, folder: info.folder, in: snapshot) {
                    result.skipped += 1
                    continue
                }
                // Made first, so that its attachments have a folder to go into.
                let note = try await store.create(folder: info.folder, markdown: incoming.markdown.components(separatedBy: "\n").first ?? "")
                // Pictures from the body, in their places.
                var text = incoming.markdown
                for (n, image) in incoming.images.enumerated() {
                    let file = work.appendingPathComponent("image-\(n).\(Self.fileExtension(forMime: image.mime))")
                    try image.data.write(to: file)
                    let link = try await store.addAsset(to: note.id, from: file)
                    text = text.replacingOccurrences(of: "(\(NotesMarkup.imagePlaceholder(n)))", with: "(\(link))")
                }
                // The attachments Notes keeps out of the body go where it left room for them, the rest at the end.
                var extra: [String] = []
                for attachment in content.attachments {
                    let url = URL(fileURLWithPath: attachment.file)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let name = attachment.name ?? url.lastPathComponent
                    if Self.isPicture(url) {
                        extra.append(Markdown.imageToMarkdown(MdImage(path: try await store.addAsset(to: note.id, from: url))))
                    } else {
                        extra.append(Markdown.fileToMarkdown(MdFile(path: try await store.addAsset(to: note.id, from: url, name: name), name: name)))
                    }
                }
                var lines = text.components(separatedBy: "\n").map { line in
                    guard line == NotesMarkup.attachmentPlaceholder else { return line }
                    return extra.isEmpty ? "" : extra.removeFirst()
                }
                lines += extra
                try await store.write(note.id, markdown: lines.joined(separator: "\n"))
                snapshot = await store.current()
                result.copied += 1
            } catch {
                result.failed.append("\(info.name): \(error.localizedDescription)")
            }
        }
        progress(Progress(done: notes.count, total: notes.count, title: ""))
        return result
    }

    private func exists(key: String, folder: String, in snapshot: NotesSnapshot) async throws -> Bool {
        for note in snapshot.notes where note.folder == folder {
            let text = try await store.read(note.id)
            if NotesMarkup.contentKey(text) == key { return true }
        }
        return false
    }

    // MARK: - Export

    /// The notes of the given folders into Notes, each into a folder of the same name.
    public func exportNotes(account: String?, folders: Set<String>, progress: (Progress) -> Void) async throws -> Result {
        library.accountName = { account }
        let snapshot = try await store.scan()
        let notes = snapshot.notes.filter { folders.contains($0.folder) }
        var existing: [String: Set<String>] = [:]
        var result = Result()
        for folder in folders { try await library.ensureFolder(folder) }
        for (index, note) in notes.enumerated() {
            progress(Progress(done: index, total: notes.count, title: note.title))
            do {
                let markdown = try await store.read(note.id)
                if existing[note.folder] == nil { existing[note.folder] = try await keysInNotes(folder: note.folder) }
                if existing[note.folder]?.contains(NotesMarkup.contentKey(markdown)) == true {
                    result.skipped += 1
                    continue
                }
                let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                // Every picture and file goes as a copy under its own name, which Notes shows.
                var copies: [String: URL] = [:]
                for (path, name) in NotesMarkup.html(fromMarkdown: markdown).files where copies[path] == nil {
                    guard let source = store.resolve(link: path, of: note), FileManager.default.fileExists(atPath: source.path) else { continue }
                    let target = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .appendingPathComponent(FileNames.decodeLink(name).replacingOccurrences(of: "/", with: "_"))
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                    copies[path] = target
                }
                let outgoing = NotesMarkup.html(fromMarkdown: markdown) { copies[$0] }
                _ = try await library.create(folder: note.folder, html: outgoing.html, files: outgoing.files.compactMap { copies[$0.path] })
                result.copied += 1
            } catch {
                result.failed.append("\(note.title): \(error.localizedDescription)")
            }
        }
        progress(Progress(done: notes.count, total: notes.count, title: ""))
        return result
    }

    /// The words of the notes already in a folder of Notes.
    private func keysInNotes(folder: String) async throws -> Set<String> {
        var keys = Set<String>()
        for info in try await library.list() where info.folder == folder {
            let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let content = try await library.read(id: info.id, into: work)
            keys.insert(NotesMarkup.contentKey(NotesMarkup.markdown(fromHTML: content.html, title: info.name).markdown))
        }
        return keys
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        default: return "jpg"
        }
    }

    static func isPicture(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased())
    }
}
#endif
