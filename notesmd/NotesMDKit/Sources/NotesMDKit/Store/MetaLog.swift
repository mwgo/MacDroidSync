import Foundation

/// What one writer knows of one note, beyond its Markdown. Every field group
/// carries the time it was set, so that the newest wins across writers.
public struct NoteMeta: Codable, Equatable, Sendable {
    /// Relative to the root: `Folder/Title.md`, or `.notesmd/trash/<id>/Title.md`
    /// for a note in the trash; nil once the note is gone for good.
    public var path: String?
    public var pathTs: Double = 0
    /// The SHA-256 of the note's text when `path` was set, by which a note
    /// renamed or moved outside the app is recognised.
    public var sha: String?
    public var created: Double?
    public var pinned: Bool?
    public var pinnedTs: Double = 0
    /// When the note went to the trash, nil for a note in use.
    public var trashed: Double?
    /// The folder a note in the trash came from, where it is restored to.
    public var folder: String?
    public var trashedTs: Double = 0
    /// Set when two ids turned out to name one note: the one that stays.
    public var mergedInto: String?

    public init() {}
}

public struct FolderMeta: Codable, Equatable, Sendable {
    public var order: Double
    public var ts: Double

    public init(order: Double, ts: Double) {
        self.order = order
        self.ts = ts
    }
}

/// The file one writer keeps in `.notesmd/devices/`. Each writer writes only
/// its own file, so iCloud never has two versions of one to reconcile.
public struct DeviceMeta: Codable, Equatable, Sendable {
    public var v = 1
    public var writer: String
    public var notes: [String: NoteMeta] = [:]
    public var folders: [String: FolderMeta] = [:]

    public init(writer: String) {
        self.writer = writer
    }
}

/// The state every writer's file adds up to: for each field, the newest value.
public struct MergedMeta: Sendable {
    public var notes: [String: NoteMeta] = [:]
    public var folders: [String: FolderMeta] = [:]

    public init(_ devices: [DeviceMeta]) {
        for device in devices {
            for (id, meta) in device.notes {
                guard var merged = notes[id] else {
                    notes[id] = meta
                    continue
                }
                if meta.pathTs > merged.pathTs {
                    merged.path = meta.path
                    merged.pathTs = meta.pathTs
                    merged.sha = meta.sha
                }
                if meta.pinnedTs > merged.pinnedTs {
                    merged.pinned = meta.pinned
                    merged.pinnedTs = meta.pinnedTs
                }
                if meta.trashedTs > merged.trashedTs {
                    merged.trashed = meta.trashed
                    merged.folder = meta.folder
                    merged.trashedTs = meta.trashedTs
                }
                if let created = meta.created { merged.created = min(merged.created ?? created, created) }
                if let into = meta.mergedInto { merged.mergedInto = min(merged.mergedInto ?? into, into) }
                notes[id] = merged
            }
            for (name, meta) in device.folders where meta.ts > (folders[name]?.ts ?? -1) {
                folders[name] = meta
            }
        }
    }

    /// The id a note goes by in the end, following merges.
    public func resolve(_ id: String) -> String {
        var current = id
        var seen: Set<String> = [id]
        while let next = notes[current]?.mergedInto, seen.insert(next).inserted { current = next }
        return current
    }
}
