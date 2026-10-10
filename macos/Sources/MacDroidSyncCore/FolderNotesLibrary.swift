import Foundation
import NotesMDKit

/// A note of the Mac as the sync hands it to the phone.
public struct LocalNote {
    public var info: MacNoteInfo
    /// In the phone's form: the attachments under `images/` and `files/`.
    public var markdown: String
    /// Every picture and file, a drawing's strokes right after its picture, as
    /// the phone's path, the file here and its checksum.
    public var assets: [(path: String, url: URL, sha256: String)]
}

/// The notes on the Mac, and the ids that changed or are not settled yet.
public struct LibraryList {
    public var notes: [MacNoteInfo]
    /// Notes whose file iCloud is still moving: not to be taken for deleted.
    public var pending: Set<String> = []
    /// Ids found to name the same note as another, with the one that stays.
    public var merged: [String: String] = [:]

    public init(notes: [MacNoteInfo], pending: Set<String> = [], merged: [String: String] = [:]) {
        self.notes = notes
        self.pending = pending
        self.merged = merged
    }
}

/// What the sync needs of the notes on the Mac.
public protocol NoteLibrary: AnyObject {
    func list() async throws -> LibraryList
    func folders() async throws -> [String]
    func read(id: String) async throws -> LocalNote
    /// Writes a note from the phone, a new one when `id` is nil. `assets` are
    /// the files, by the phone's path, the Mac does not have as they are. With
    /// `baseHash`, only over the version the sync last saw.
    func write(id: String?, folder: String, markdown: String, assets: [String: URL], baseHash: String?) async throws -> MacNoteInfo
    func move(id: String, folder: String) async throws -> MacNoteInfo
    /// Into the trash.
    func delete(id: String) async throws
    func ensureFolder(_ name: String) async throws
    /// Removes a folder with no note in it; false when it still has some.
    func deleteFolder(_ name: String) async throws -> Bool
}

/// The notes in the folder Notes MD keeps on iCloud Drive.
public final class FolderNotesLibrary: NoteLibrary {
    public let store: FolderStore

    private var notes: [String: Cached] = [:]
    private var checksums: [String: (modified: Date, size: Int, sha: String)] = [:]

    private struct Cached {
        var key: String
        var note: LocalNote
    }

    public init(root: URL, writer: String, clock: @escaping @Sendable () -> Date = Date.init) {
        store = FolderStore(root: root, writer: writer, clock: clock)
    }

    public func list() async throws -> LibraryList {
        let snapshot = try await store.scan()
        var infos: [MacNoteInfo] = []
        for record in snapshot.notes where record.isDownloaded {
            guard let note = try? await local(record) else { continue }
            infos.append(note.info)
        }
        notes = notes.filter { id, _ in snapshot.notes.contains { $0.id == id } }
        return LibraryList(notes: infos, pending: snapshot.pending, merged: snapshot.merged)
    }

    public func folders() async throws -> [String] {
        try await store.scan().folders.map(\.name)
    }

    public func read(id: String) async throws -> LocalNote {
        guard let record = try await store.scan().notes.first(where: { $0.id == id }) else { throw FolderStoreError.missing }
        return try await local(record)
    }

    public func write(id: String?, folder: String, markdown: String, assets: [String: URL], baseHash: String?) async throws -> MacNoteInfo {
        var record: NoteRecord
        if let id {
            guard let existing = try await store.scan().notes.first(where: { $0.id == id }) else { throw FolderStoreError.missing }
            if let baseHash, try await local(existing).info.hash != baseHash { throw FolderStoreError.changed }
            record = existing
            if record.folder != folder { record = try await store.move(id, to: folder) }
        } else {
            record = try await store.create(folder: folder, markdown: markdown)
        }
        for (wire, file) in assets {
            guard let local = WireForm.localPath(wire, assetsFolder: record.assetsFolder) else { continue }
            try await store.putAsset(of: record.id, inner: String(local.dropFirst(record.assetsFolder.count + 1)), from: file)
        }
        record = try await store.write(record.id, markdown: WireForm.fromWire(markdown, assetsFolder: record.assetsFolder))
        return try await local(record).info
    }

    public func move(id: String, folder: String) async throws -> MacNoteInfo {
        let record = try await store.move(id, to: folder)
        return try await local(record).info
    }

    public func delete(id: String) async throws {
        try await store.trash(id)
    }

    public func ensureFolder(_ name: String) async throws {
        let snapshot = try await store.scan()
        guard !snapshot.folders.contains(where: { $0.name == name }) else { return }
        try await store.createFolder(name)
    }

    public func deleteFolder(_ name: String) async throws -> Bool {
        let snapshot = try await store.scan()
        guard snapshot.folders.contains(where: { $0.name == name }) else { return true }
        if snapshot.notes.contains(where: { $0.folder == name }) || !snapshot.pending.isEmpty { return false }
        try await store.deleteFolder(name)
        return true
    }

    /// The note in the phone's form, read again only when its file or its attachments changed.
    private func local(_ record: NoteRecord) async throws -> LocalNote {
        let assetsURL = store.assetsURL(of: record)
        let assetsStamp = (try? assetsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(record.sha)|\(record.path)|\(record.folder)|\(assetsStamp)"
        if let cached = notes[record.id], cached.key == key { return cached.note }

        let text = try await store.read(record.id)
        let wire = WireForm.toWire(text, assetsFolder: record.assetsFolder)
        let directory = store.url(of: record.path).deletingLastPathComponent()
        var assets: [(path: String, url: URL, sha256: String)] = []
        for asset in wire.assets {
            let url = asset.local.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
            guard let sha = checksum(url) else { continue }
            assets.append((asset.wire, url, sha))
            if asset.wire.hasPrefix(WireForm.images), !asset.wire.hasSuffix(".json") {
                let strokes = URL(fileURLWithPath: WireForm.strokesPath(url.path))
                if let strokesSha = checksum(strokes) { assets.append((WireForm.strokesPath(asset.wire), strokes, strokesSha)) }
            }
        }
        let hash = NoteHash.hash(markdown: wire.markdown, assets: assets.map { ($0.path, $0.sha256) })
        let info = MacNoteInfo(
            id: record.id,
            name: record.title,
            folder: record.folder,
            modified: Int64(record.modified.timeIntervalSince1970 * 1000),
            hash: hash
        )
        let note = LocalNote(info: info, markdown: wire.markdown, assets: assets)
        notes[record.id] = Cached(key: key, note: note)
        return note
    }

    private func checksum(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        let size = values.fileSize ?? 0
        if let known = checksums[url.path], known.modified == modified, known.size == size { return known.sha }
        guard let sha = try? NoteHash.sha256(file: url) else { return nil }
        checksums[url.path] = (modified, size, sha)
        return sha
    }
}

extension FolderStoreError: FolderStoreErrorConvertible {
    public var isChanged: Bool { self == .changed }
}
