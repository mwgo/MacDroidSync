import Foundation

/// One note in the folder.
public struct NoteRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    /// Relative to the root, `Folder/Title.md`; in the trash `.notesmd/trash/<id>/Title.md`.
    public var path: String
    /// The folder the note is in, or for a note in the trash the one it came from.
    public var folder: String
    public var summary: NoteSummary
    public var created: Date
    public var modified: Date
    public var pinned: Bool
    public var trashed: Date?
    /// SHA-256 of the note's text; empty while iCloud has not brought the file down yet.
    public var sha: String
    public var isDownloaded: Bool

    /// The file's name without `.md`, which the title gives.
    public var fileBase: String {
        let name = (path as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    /// The name of the folder of its pictures and files, next to the note.
    public var assetsFolder: String { FileNames.assetsFolder(forBase: fileBase) }

    public var title: String { summary.title.isEmpty ? FileNames.untitled : summary.title }
}

public struct FolderRecord: Identifiable, Equatable, Hashable, Sendable {
    public var name: String
    public var order: Double
    public var id: String { name }
}

/// Everything in the folder at one moment.
public struct NotesSnapshot: Equatable, Sendable {
    public var folders: [FolderRecord] = []
    /// The notes in use.
    public var notes: [NoteRecord] = []
    /// The notes in the trash, newest deletion first.
    public var trash: [NoteRecord] = []
    /// Notes whose file has gone and may be on its way back, a rename on
    /// another device iCloud has told of but not carried out yet. Neither in
    /// use nor deleted until that settles.
    public var pending: Set<String> = []
    /// Ids found to name the same note as another, with the one that stays.
    public var merged: [String: String] = [:]

    public init() {}

    public func note(_ id: String) -> NoteRecord? {
        notes.first { $0.id == id } ?? trash.first { $0.id == id }
    }
}

public enum FolderStoreError: LocalizedError, Equatable {
    case missing
    /// The note changed since the version the change was made against.
    case changed
    case exists
    case badName
    case lastFolder

    public var errorDescription: String? {
        switch self {
        case .missing: return "The note is no longer there."
        case .changed: return "The note was changed elsewhere in the meantime."
        case .exists: return "There already is a folder of that name."
        case .badName: return "That name cannot be used."
        case .lastFolder: return "The last folder cannot be deleted."
        }
    }
}

/// The notes in a folder, most likely on iCloud Drive, shared by Notes MD on
/// every device and by MacDroidSync. Each note is a Markdown file in a folder
/// of the root, its attachments next to it in `Title.assets`; what Markdown
/// cannot hold - a lasting id, pinning, the trash - lives in `.notesmd`, one
/// file per writer.
///
/// Every change goes through `NSFileCoordinator`, so that iCloud and the other
/// processes on the Mac see it whole.
public actor FolderStore {
    public nonisolated let root: URL
    public nonisolated let writer: String

    /// How long a note stays in the trash.
    public static let trashDays = 30.0
    /// How long a change iCloud is still bringing in is waited for before what is there counts.
    static let settleSeconds = 120.0

    private let clock: @Sendable () -> Date
    private var own: DeviceMeta
    private var ownDirty = false
    private var merged = MergedMeta([])
    private var snapshot = NotesSnapshot()
    private var cache: [String: Cached] = [:]
    /// When this process first saw a file no id claims, by path.
    private var firstSeen: [String: Date] = [:]

    private struct Cached {
        var modified: Date
        var size: Int
        var sha: String
        var summary: NoteSummary
    }

    private struct DiskFile {
        var url: URL
        var modified: Date
        var created: Date
        var size: Int
        var downloaded: Bool
    }

    public init(root: URL, writer: String, clock: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.writer = writer
        self.clock = clock
        let ownURL = root.appendingPathComponent(FileNames.metaFolder).appendingPathComponent("devices").appendingPathComponent(Self.fileName(writer: writer))
        if let data = try? Coordinated.read(ownURL), let meta = try? JSONDecoder().decode(DeviceMeta.self, from: data) {
            own = meta
        } else {
            own = DeviceMeta(writer: writer)
        }
    }

    // MARK: - Places

    private var metaURL: URL { root.appendingPathComponent(FileNames.metaFolder, isDirectory: true) }
    private var devicesURL: URL { metaURL.appendingPathComponent("devices", isDirectory: true) }
    private var trashURL: URL { metaURL.appendingPathComponent("trash", isDirectory: true) }
    private var ownURL: URL { devicesURL.appendingPathComponent(Self.fileName(writer: writer)) }

    private static func fileName(writer: String) -> String {
        writer.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.reduce(into: "") { $0.append($1) } + ".json"
    }

    public nonisolated func url(of path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// The folder holding a note's pictures and files.
    public nonisolated func assetsURL(of note: NoteRecord) -> URL {
        url(of: note.path).deletingLastPathComponent().appendingPathComponent(note.assetsFolder, isDirectory: true)
    }

    /// Where a link of the note's Markdown points, or nil for one outside the folder of notes.
    public nonisolated func resolve(link: String, of note: NoteRecord) -> URL? {
        let path = FileNames.decodeLink(link)
        guard !path.contains("://"), !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return path.split(separator: "/").reduce(url(of: note.path).deletingLastPathComponent()) { $0.appendingPathComponent(String($1)) }
    }

    // MARK: - Reading the folder

    public func current() -> NotesSnapshot { snapshot }

    /// Reads the folder again: what is on disk and what every writer said of it.
    @discardableResult
    public func scan() throws -> NotesSnapshot {
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        merged = MergedMeta(loadDevices())
        let now = clock()

        var folders: [String] = []
        var disk: [String: DiskFile] = [:]
        for entry in list(root) where entry.isDirectory {
            let name = entry.name
            guard !name.hasPrefix("."), !name.hasSuffix(FileNames.assetsSuffix) else { continue }
            folders.append(name)
            for file in list(entry.url) where !file.isDirectory {
                guard let (base, downloaded) = Self.noteFile(file.name) else { continue }
                let path = name + "/" + base + "." + FileNames.noteExtension
                let url = entry.url.appendingPathComponent(base + "." + FileNames.noteExtension)
                if !downloaded { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                disk[path] = DiskFile(url: downloaded ? file.url : url, modified: file.modified, created: file.created, size: file.size, downloaded: downloaded)
            }
        }
        for entry in list(trashURL) where entry.isDirectory {
            for file in list(entry.url) where !file.isDirectory {
                guard let (base, downloaded) = Self.noteFile(file.name) else { continue }
                let path = FileNames.metaFolder + "/trash/" + entry.name + "/" + base + "." + FileNames.noteExtension
                let url = entry.url.appendingPathComponent(base + "." + FileNames.noteExtension)
                if !downloaded { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                disk[path] = DiskFile(url: downloaded ? file.url : url, modified: file.modified, created: file.created, size: file.size, downloaded: downloaded)
            }
        }
        cache = cache.filter { disk[$0.key] != nil }
        for (path, file) in disk where file.downloaded && !path.hasPrefix(FileNames.metaFolder + "/") {
            if let cached = cache[path], cached.modified == file.modified, cached.size == file.size { continue }
            if let copy = keepConflicts(of: file.url) {
                let entry = list(copy.deletingLastPathComponent()).first { $0.url.lastPathComponent == copy.lastPathComponent }
                let folder = path.split(separator: "/")[0]
                disk[folder + "/" + copy.lastPathComponent.precomposedStringWithCanonicalMapping] = DiskFile(
                    url: copy, modified: entry?.modified ?? now, created: entry?.created ?? now, size: entry?.size ?? 0, downloaded: true)
            }
        }

        var claims: [String: [String]] = [:]
        for (id, meta) in merged.notes where meta.mergedInto == nil {
            if let path = meta.path { claims[path.precomposedStringWithCanonicalMapping, default: []].append(id) }
        }
        var ids: [String: String] = [:]
        var unclaimed: [String] = []
        for path in disk.keys.sorted() {
            guard let claiming = claims[path] else {
                unclaimed.append(path)
                continue
            }
            let winner = claiming.min()!
            ids[path] = winner
            for other in claiming where other != winner {
                change(other) { $0.mergedInto = winner }
            }
        }
        var dangling = merged.notes.filter { id, meta in
            guard meta.mergedInto == nil, let path = meta.path else { return false }
            return disk[path.precomposedStringWithCanonicalMapping] == nil
        }
        var skipped = Set<String>()
        for path in unclaimed {
            guard let file = disk[path], file.downloaded, let info = info(path, file) else {
                skipped.insert(path)
                continue
            }
            if path.hasPrefix(FileNames.metaFolder + "/") {
                // A note in the trash names its id in its folder.
                let id = path.split(separator: "/")[2].lowercased()
                change(id) {
                    $0.path = path
                    $0.pathTs = now.timeIntervalSince1970
                    $0.sha = info.sha
                    if $0.trashed == nil {
                        $0.trashed = file.modified.timeIntervalSince1970
                        $0.trashedTs = now.timeIntervalSince1970
                    }
                }
                dangling[id] = nil
                ids[path] = id
                continue
            }
            if let (id, meta) = dangling.first(where: { $0.value.sha == info.sha }) {
                let movedHere = meta.pathTs <= file.modified.timeIntervalSince1970 + 1
                let seen = firstSeen[path] ?? now
                firstSeen[path] = seen
                if !movedHere, now.timeIntervalSince(seen) < Self.settleSeconds {
                    // Most likely where the note was before a rename iCloud has not carried out here yet.
                    skipped.insert(path)
                    continue
                }
                change(id) {
                    $0.path = path
                    $0.pathTs = now.timeIntervalSince1970
                    $0.sha = info.sha
                }
                dangling[id] = nil
                ids[path] = id
                firstSeen[path] = nil
                continue
            }
            let id = Self.stableId(path: path, sha: info.sha)
            change(id) {
                $0.path = path
                $0.pathTs = max($0.pathTs, file.modified.timeIntervalSince1970)
                $0.sha = info.sha
                if $0.created == nil { $0.created = file.created.timeIntervalSince1970 }
            }
            ids[path] = id
            firstSeen[path] = nil
        }
        merged = MergedMeta(devicesForMerge())

        var next = NotesSnapshot()
        for (path, id) in ids {
            guard let file = disk[path], let meta = merged.notes[id] else { continue }
            let info = file.downloaded ? self.info(path, file) : nil
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let inTrash = path.hasPrefix(FileNames.metaFolder + "/")
            let record = NoteRecord(
                id: id,
                path: path,
                folder: inTrash ? (meta.folder ?? folders.first ?? FileNames.untitled) : String(path.split(separator: "/")[0]),
                summary: info?.summary ?? NoteSummary(title: base, preview: "", image: nil),
                created: meta.created.map(Date.init(timeIntervalSince1970:)) ?? file.created,
                modified: file.modified,
                pinned: meta.pinned ?? false,
                trashed: inTrash ? Date(timeIntervalSince1970: meta.trashed ?? file.modified.timeIntervalSince1970) : nil,
                sha: info?.sha ?? meta.sha ?? "",
                isDownloaded: file.downloaded
            )
            if inTrash { next.trash.append(record) } else { next.notes.append(record) }
        }
        next.trash.sort { ($0.trashed ?? .distantPast) > ($1.trashed ?? .distantPast) }
        for (id, meta) in merged.notes where meta.mergedInto != nil { next.merged[id] = merged.resolve(id) }
        next.notes.sort { $0.modified > $1.modified }
        for (id, meta) in dangling where now.timeIntervalSince1970 - meta.pathTs < Self.settleSeconds {
            next.pending.insert(id)
        }
        if !skipped.isEmpty {
            // Files still on their way: whatever note they turn out to be is not settled yet.
            for (id, _) in dangling { next.pending.insert(id) }
        }

        var order: [String: Double] = [:]
        var last = merged.folders.values.map(\.order).max() ?? 0
        for name in folders.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if let known = merged.folders[name] {
                order[name] = known.order
            } else {
                last += 1
                order[name] = last
            }
        }
        next.folders = folders.map { FolderRecord(name: $0, order: order[$0] ?? 0) }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name }
        snapshot = next
        try saveOwn()
        return next
    }

    /// `Title.md`, or the stand-in iCloud leaves on iOS for one not downloaded, `.Title.md.icloud`.
    private static func noteFile(_ name: String) -> (base: String, downloaded: Bool)? {
        let suffix = "." + FileNames.noteExtension
        if name.hasPrefix("."), name.hasSuffix(suffix + ".icloud") {
            let inner = String(name.dropFirst().dropLast(".icloud".count))
            return (String(inner.dropLast(suffix.count)), false)
        }
        guard !name.hasPrefix("."), name.lowercased().hasSuffix(suffix), name.count > suffix.count else { return nil }
        return (String(name.dropLast(suffix.count)).precomposedStringWithCanonicalMapping, true)
    }

    /// An id every device works out alike for the same file, so that two of
    /// them meeting a new note at once still agree what it is called.
    static func stableId(path: String, sha: String) -> String {
        let digest = NoteHash.sha256(path.precomposedStringWithCanonicalMapping + "\n" + sha)
        let hex = Array(digest.prefix(32))
        return [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]].map { String($0) }.joined(separator: "-")
    }

    /// Two devices changed one note before iCloud brought either change to the
    /// other: the version iCloud chose stays, each other one becomes a note of
    /// its own next to it, "Title (conflict 2026-10-10 12.30)". Returns the last copy made.
    private func keepConflicts(of url: URL) -> URL? {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return nil }
        var made: URL?
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        for version in versions {
            guard let data = try? Data(contentsOf: version.url) else { continue }
            let stamp = " (conflict " + formatter.string(from: version.modificationDate ?? clock()) + ")"
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if let first = lines.first, !first.trimmingCharacters(in: .whitespaces).isEmpty { lines[0] = first + stamp }
            let markdown = lines.joined(separator: "\n")
            let directory = url.deletingLastPathComponent()
            let base = FileNames.unique(FileNames.base(forTitle: Markdown.title(markdown)), taken: names(in: directory))
            let oldBase = url.deletingPathExtension().lastPathComponent
            let assets = directory.appendingPathComponent(FileNames.assetsFolder(forBase: oldBase), isDirectory: true)
            if FileManager.default.fileExists(atPath: assets.path) {
                try? Coordinated.copy(assets, to: directory.appendingPathComponent(FileNames.assetsFolder(forBase: base), isDirectory: true))
            }
            let text = Self.relink(markdown, from: FileNames.assetsFolder(forBase: oldBase), to: FileNames.assetsFolder(forBase: base))
            let target = directory.appendingPathComponent(base + "." + FileNames.noteExtension)
            if (try? Coordinated.write(Data(text.utf8), to: target)) != nil { made = target }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return made
    }

    private func info(_ path: String, _ file: DiskFile) -> Cached? {
        if let cached = cache[path], cached.modified == file.modified, cached.size == file.size { return cached }
        guard let data = try? Coordinated.read(file.url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let cached = Cached(modified: file.modified, size: file.size, sha: NoteHash.sha256(data), summary: NoteSummary.of(text))
        cache[path] = cached
        return cached
    }

    private struct Entry {
        var name: String
        var url: URL
        var isDirectory: Bool
        var modified: Date
        var created: Date
        var size: Int
    }

    private func list(_ directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                name: url.lastPathComponent.precomposedStringWithCanonicalMapping,
                url: url,
                isDirectory: values?.isDirectory ?? false,
                modified: values?.contentModificationDate ?? .distantPast,
                created: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0
            )
        }
    }

    private func loadDevices() -> [DeviceMeta] {
        var devices: [DeviceMeta] = []
        for entry in list(devicesURL) where !entry.isDirectory {
            if entry.name.hasPrefix("."), entry.name.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: entry.url)
                continue
            }
            guard entry.name.hasSuffix(".json"), entry.name != Self.fileName(writer: writer),
                  let data = try? Coordinated.read(entry.url),
                  let meta = try? JSONDecoder().decode(DeviceMeta.self, from: data) else { continue }
            devices.append(meta)
        }
        others = devices
        return devices + [own]
    }

    private var others: [DeviceMeta] = []

    private func devicesForMerge() -> [DeviceMeta] { others + [own] }

    private func change(_ id: String, _ update: (inout NoteMeta) -> Void) {
        var meta = own.notes[id] ?? NoteMeta()
        let before = meta
        update(&meta)
        guard meta != before else { return }
        own.notes[id] = meta
        ownDirty = true
    }

    private func saveOwn() throws {
        guard ownDirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Coordinated.write(try encoder.encode(own), to: ownURL)
        ownDirty = false
    }

    // MARK: - Notes

    public func read(_ id: String) throws -> String {
        let note = try record(id)
        return String(decoding: try Coordinated.read(url(of: note.path)), as: UTF8.self)
    }

    private func record(_ id: String) throws -> NoteRecord {
        if let note = snapshot.note(id) { return note }
        try scan()
        if let note = snapshot.note(merged.resolve(id)) { return note }
        throw FolderStoreError.missing
    }

    /// A new note in `folder`, made if missing, named after its title.
    @discardableResult
    public func create(folder: String, markdown: String) throws -> NoteRecord {
        let folderName = FileNames.folderName(folder)
        let directory = url(of: folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileNames.unique(FileNames.base(forTitle: Markdown.title(markdown)), taken: names(in: directory))
        let path = folderName + "/" + base + "." + FileNames.noteExtension
        let data = Data(markdown.utf8)
        try Coordinated.write(data, to: url(of: path))
        let id = UUID().uuidString.lowercased()
        let now = clock().timeIntervalSince1970
        change(id) {
            $0.path = path
            $0.pathTs = now
            $0.sha = NoteHash.sha256(data)
            $0.created = now
        }
        try scan()
        return try record(id)
    }

    /// Writes a note's text. With `baseSHA`, only over the version it was read
    /// at. With `rename`, the file follows a changed title, its attachments with it.
    @discardableResult
    public func write(_ id: String, markdown: String, baseSHA: String? = nil, rename: Bool = true) throws -> NoteRecord {
        var note = try record(id)
        guard note.trashed == nil else { throw FolderStoreError.missing }
        let fileURL = url(of: note.path)
        if let baseSHA {
            let now = (try? Coordinated.read(fileURL)).map(NoteHash.sha256) ?? ""
            if now != baseSHA { throw FolderStoreError.changed }
        }
        var text = markdown
        if rename {
            let wanted = FileNames.base(forTitle: Markdown.title(markdown))
            if !FileNames.isVariant(note.fileBase, of: wanted) {
                let directory = fileURL.deletingLastPathComponent()
                let base = FileNames.unique(wanted, taken: names(in: directory).subtracting([note.fileBase]))
                text = try moveFiles(of: note, to: directory, base: base, markdown: text)
                note.path = note.folder + "/" + base + "." + FileNames.noteExtension
            }
        }
        let data = Data(text.utf8)
        try Coordinated.write(data, to: url(of: note.path))
        removeUnused(of: note, markdown: text)
        let path = note.path
        change(note.id) {
            $0.path = path
            $0.pathTs = clock().timeIntervalSince1970
            $0.sha = NoteHash.sha256(data)
        }
        try scan()
        return try record(note.id)
    }

    /// Renames or moves a note's file and its attachments' folder together,
    /// and returns its Markdown with the links into the new folder.
    private func moveFiles(of note: NoteRecord, to directory: URL, base: String, markdown: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fromAssets = assetsURL(of: note)
        let toAssets = directory.appendingPathComponent(FileNames.assetsFolder(forBase: base), isDirectory: true)
        let target = directory.appendingPathComponent(base + "." + FileNames.noteExtension)
        if FileManager.default.fileExists(atPath: fromAssets.path), fromAssets.standardizedFileURL != toAssets.standardizedFileURL {
            try? Coordinated.remove(toAssets)
            try Coordinated.move(fromAssets, to: toAssets)
        }
        if url(of: note.path).standardizedFileURL != target.standardizedFileURL {
            try Coordinated.move(url(of: note.path), to: target)
        }
        return Self.relink(markdown, from: note.assetsFolder, to: FileNames.assetsFolder(forBase: base))
    }

    /// The links into one attachments folder pointed at another.
    static func relink(_ markdown: String, from: String, to: String) -> String {
        guard from != to else { return markdown }
        return markdown.components(separatedBy: "\n").map { line -> String in
            guard let link = Markdown.parseImage(line)?.path ?? Markdown.parseFile(line)?.path else { return line }
            let path = FileNames.decodeLink(link)
            guard path.hasPrefix(from + "/") else { return line }
            return WireForm.replaceLink(in: line, from: link, to: FileNames.encodeLink(to + path.dropFirst(from.count)))
        }.joined(separator: "\n")
    }

    /// Takes out the pictures and files the note no longer shows, and their folder once it is empty.
    private func removeUnused(of note: NoteRecord, markdown: String) {
        let folder = assetsURL(of: note)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var used = Set<String>()
        for link in Markdown.assetPaths(markdown) {
            let path = FileNames.decodeLink(link)
            guard path.hasPrefix(note.assetsFolder + "/") else { continue }
            let inner = String(path.dropFirst(note.assetsFolder.count + 1))
            used.insert(inner)
            used.insert(WireForm.strokesPath(inner))
            if let first = inner.split(separator: "/").first, inner.contains("/") { used.insert(String(first)) }
        }
        for entry in list(folder) {
            let name = entry.name
            if entry.isDirectory {
                if !used.contains(name) { try? Coordinated.remove(entry.url) }
            } else if !used.contains(name) {
                try? Coordinated.remove(entry.url)
            }
        }
        if list(folder).isEmpty { try? Coordinated.remove(folder) }
    }

    private func names(in directory: URL) -> Set<String> {
        Set(list(directory).compactMap { entry -> String? in
            if entry.isDirectory {
                return entry.name.hasSuffix(FileNames.assetsSuffix) ? String(entry.name.dropLast(FileNames.assetsSuffix.count)) : nil
            }
            return Self.noteFile(entry.name)?.base
        })
    }

    /// Keeps a picture or file in the note's attachments folder and returns the
    /// link to it. `name` is the file's own name for a file, nil for a picture,
    /// which is named by a new UUID with `ext`.
    public func addAsset(to id: String, from source: URL, name: String? = nil, ext: String? = nil) throws -> String {
        let note = try record(id)
        let folder = assetsURL(of: note)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let uuid = UUID().uuidString.lowercased()
        let inner: String
        if let name {
            let safe = name.replacingOccurrences(of: "[\\s()\\[\\]/\\\\:*?\"<>|]+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            inner = uuid + "/" + (safe.isEmpty ? "file" : safe)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(uuid, isDirectory: true), withIntermediateDirectories: true)
        } else {
            inner = uuid + "." + (ext ?? source.pathExtension.lowercased())
        }
        let target = inner.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
        try Coordinated.copy(source, to: target)
        return FileNames.encodeLink(note.assetsFolder + "/" + inner)
    }

    /// Writes bytes into the note's attachments folder at `inner` (e.g. `x.json`), replacing what is there.
    public func writeAsset(of id: String, inner: String, data: Data) throws {
        let note = try record(id)
        let folder = assetsURL(of: note)
        let target = inner.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Coordinated.write(data, to: target)
    }

    /// Puts a file into the note's attachments folder at `inner` (e.g. `<uuid>.jpg`), replacing what is there.
    public func putAsset(of id: String, inner: String, from source: URL) throws {
        let note = try record(id)
        let target = inner.split(separator: "/").reduce(assetsURL(of: note)) { $0.appendingPathComponent(String($1)) }
        try Coordinated.copy(source, to: target)
    }

    /// Into another folder, made if missing; the note keeps its name unless the folder has one like it.
    @discardableResult
    public func move(_ id: String, to folder: String) throws -> NoteRecord {
        let note = try record(id)
        let folderName = FileNames.folderName(folder)
        guard note.trashed == nil, note.folder != folderName else { return note }
        let markdown = try read(id)
        let directory = url(of: folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileNames.unique(note.fileBase, taken: names(in: directory))
        let text = try moveFiles(of: note, to: directory, base: base, markdown: markdown)
        if text != markdown { try Coordinated.write(Data(text.utf8), to: directory.appendingPathComponent(base + "." + FileNames.noteExtension)) }
        let path = folderName + "/" + base + "." + FileNames.noteExtension
        change(id) {
            $0.path = path
            $0.pathTs = clock().timeIntervalSince1970
            $0.sha = NoteHash.sha256(text)
        }
        try scan()
        return try record(id)
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws {
        let note = try record(id)
        change(note.id) {
            $0.pinned = pinned
            $0.pinnedTs = clock().timeIntervalSince1970
        }
        try scan()
    }

    /// Into the trash, kept there for `trashDays`.
    public func trash(_ id: String) throws {
        let note = try record(id)
        guard note.trashed == nil else { return }
        let markdown = try read(id)
        let directory = trashURL.appendingPathComponent(note.id, isDirectory: true)
        try? Coordinated.remove(directory)
        let text = try moveFiles(of: note, to: directory, base: note.fileBase, markdown: markdown)
        let now = clock().timeIntervalSince1970
        let path = FileNames.metaFolder + "/trash/" + note.id + "/" + note.fileBase + "." + FileNames.noteExtension
        change(note.id) {
            $0.path = path
            $0.pathTs = now
            $0.sha = NoteHash.sha256(text)
            $0.trashed = now
            $0.folder = note.folder
            $0.trashedTs = now
        }
        try scan()
    }

    /// Out of the trash, back into the folder it came from, as if just written.
    @discardableResult
    public func restore(_ id: String, to folder: String? = nil) throws -> NoteRecord {
        let note = try record(id)
        guard note.trashed != nil else { return note }
        let markdown = try read(id)
        let folderName = FileNames.folderName(folder ?? note.folder)
        let directory = url(of: folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileNames.unique(note.fileBase, taken: names(in: directory))
        let text = try moveFiles(of: note, to: directory, base: base, markdown: markdown)
        let target = directory.appendingPathComponent(base + "." + FileNames.noteExtension)
        try Coordinated.write(Data(text.utf8), to: target)
        try? Coordinated.remove(trashURL.appendingPathComponent(note.id, isDirectory: true))
        let now = clock().timeIntervalSince1970
        let path = folderName + "/" + base + "." + FileNames.noteExtension
        change(note.id) {
            $0.path = path
            $0.pathTs = now
            $0.sha = NoteHash.sha256(text)
            $0.trashed = nil
            $0.trashedTs = now
        }
        try scan()
        return try record(note.id)
    }

    /// Gone for good, its pictures and files with it.
    public func deleteForever(_ id: String) throws {
        let note = try record(id)
        if note.trashed != nil {
            try? Coordinated.remove(trashURL.appendingPathComponent(note.id, isDirectory: true))
        } else {
            try? Coordinated.remove(assetsURL(of: note))
            try? Coordinated.remove(url(of: note.path))
        }
        change(note.id) {
            $0.path = nil
            $0.pathTs = clock().timeIntervalSince1970
        }
        try scan()
    }

    /// Empties the trash of what has been there longer than `trashDays`.
    public func purgeTrash() throws {
        let limit = clock().addingTimeInterval(-Self.trashDays * 86400)
        let old = snapshot.trash.filter { ($0.trashed ?? .distantFuture) < limit }
        for note in old { try deleteForever(note.id) }
    }

    /// A copy in the same folder, not pinned, its title followed by `titleSuffix`, its attachments copied too.
    @discardableResult
    public func duplicate(_ id: String, titleSuffix: String = " (copy)") throws -> NoteRecord {
        let note = try record(id)
        var lines = try read(id).components(separatedBy: "\n")
        if let first = lines.first, !first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines[0] = first.trimmingCharacters(in: .whitespaces) + titleSuffix
        }
        let markdown = lines.joined(separator: "\n")
        let directory = url(of: note.folder)
        let base = FileNames.unique(FileNames.base(forTitle: Markdown.title(markdown)), taken: names(in: directory))
        let assets = assetsURL(of: note)
        if FileManager.default.fileExists(atPath: assets.path) {
            try Coordinated.copy(assets, to: directory.appendingPathComponent(FileNames.assetsFolder(forBase: base), isDirectory: true))
        }
        let text = Self.relink(markdown, from: note.assetsFolder, to: FileNames.assetsFolder(forBase: base))
        let path = note.folder + "/" + base + "." + FileNames.noteExtension
        let data = Data(text.utf8)
        try Coordinated.write(data, to: url(of: path))
        let newId = UUID().uuidString.lowercased()
        let now = clock().timeIntervalSince1970
        change(newId) {
            $0.path = path
            $0.pathTs = now
            $0.sha = NoteHash.sha256(data)
            $0.created = now
        }
        try scan()
        return try record(newId)
    }

    // MARK: - Folders

    @discardableResult
    public func createFolder(_ name: String) throws -> String {
        let clean = FileNames.folderName(name)
        guard !clean.isEmpty else { throw FolderStoreError.badName }
        if snapshot.folders.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { throw FolderStoreError.exists }
        try FileManager.default.createDirectory(at: url(of: clean), withIntermediateDirectories: true)
        own.folders[clean] = FolderMeta(order: (snapshot.folders.map(\.order).max() ?? 0) + 1, ts: clock().timeIntervalSince1970)
        ownDirty = true
        try scan()
        return clean
    }

    public func renameFolder(_ from: String, to: String) throws {
        let clean = FileNames.folderName(to)
        guard clean != from else { return }
        if clean.caseInsensitiveCompare(from) != .orderedSame,
           snapshot.folders.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            throw FolderStoreError.exists
        }
        let inside = snapshot.notes.filter { $0.folder == from }
        try Coordinated.move(url(of: from), to: url(of: clean))
        let now = clock().timeIntervalSince1970
        for note in inside {
            let path = clean + "/" + (note.path as NSString).lastPathComponent
            change(note.id) {
                $0.path = path
                $0.pathTs = now
            }
        }
        for note in snapshot.trash where note.folder == from {
            change(note.id) {
                $0.folder = clean
                $0.trashedTs = now
            }
        }
        let order = snapshot.folders.first { $0.name == from }?.order ?? 0
        own.folders[clean] = FolderMeta(order: order, ts: now)
        ownDirty = true
        cache = [:]
        try scan()
    }

    /// Removes a folder, its notes into the trash, as Notes does.
    public func deleteFolder(_ name: String) throws {
        for note in snapshot.notes where note.folder == name { try trash(note.id) }
        let directory = url(of: name)
        if list(directory).isEmpty || list(directory).allSatisfy({ $0.name.hasPrefix(".") }) {
            try Coordinated.remove(directory)
        }
        try scan()
    }

    /// The folders in this order.
    public func reorderFolders(_ names: [String]) throws {
        let now = clock().timeIntervalSince1970
        for (index, name) in names.enumerated() {
            own.folders[name] = FolderMeta(order: Double(index + 1), ts: now)
        }
        ownDirty = true
        try scan()
    }
}
