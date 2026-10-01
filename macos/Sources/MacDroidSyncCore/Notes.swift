import Foundation

/// One note as the phone describes it, see PROTOCOL.md section 10.
public struct NoteEntry: Codable, Equatable {
    public var id: String
    public var folder: String
    public var title: String
    /// The phone's edit time, milliseconds.
    public var modified: Int64
    /// The text and every picture and file of the note, hashed together.
    public var hash: String
    /// Set for a note in the phone's trash: that is how a deletion is learnt.
    public var deleted: Bool?

    public init(id: String, folder: String, title: String, modified: Int64, hash: String, deleted: Bool? = nil) {
        self.id = id
        self.folder = folder
        self.title = title
        self.modified = modified
        self.hash = hash
        self.deleted = deleted
    }

    public var isDeleted: Bool { deleted == true }
}

/// A picture or file of a note: its path under the phone's notes folder.
public struct NoteAsset: Codable, Equatable {
    public var path: String
    public var size: Int64
    public var sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// A whole note, as `notes-get` brings it.
public struct NoteDoc: Codable, Equatable {
    public var id: String
    public var folder: String
    public var markdown: String
    public var hash: String
    public var assets: [NoteAsset]

    public init(id: String, folder: String, markdown: String, hash: String, assets: [NoteAsset]) {
        self.id = id
        self.folder = folder
        self.markdown = markdown
        self.hash = hash
        self.assets = assets
    }
}

/// The `notes` field of a message. Which fields are set depends on the type,
/// see the table in PROTOCOL.md section 10.
public struct NotesPayload: Codable, Equatable {
    public var requestId: String?
    public var enabled: Bool?
    public var folders: [String]?
    public var notes: [NoteEntry]?
    public var note: NoteDoc?
    public var id: String?
    public var folder: String?
    public var markdown: String?
    public var baseHash: String?
    public var hash: String?
    public var titleSuffix: String?
    public var path: String?
    public var offset: Int64?
    public var total: Int64?
    public var sha256: String?

    public init(
        requestId: String? = nil,
        enabled: Bool? = nil,
        folders: [String]? = nil,
        notes: [NoteEntry]? = nil,
        note: NoteDoc? = nil,
        id: String? = nil,
        folder: String? = nil,
        markdown: String? = nil,
        baseHash: String? = nil,
        hash: String? = nil,
        titleSuffix: String? = nil,
        path: String? = nil,
        offset: Int64? = nil,
        total: Int64? = nil,
        sha256: String? = nil
    ) {
        self.requestId = requestId
        self.enabled = enabled
        self.folders = folders
        self.notes = notes
        self.note = note
        self.id = id
        self.folder = folder
        self.markdown = markdown
        self.baseHash = baseHash
        self.hash = hash
        self.titleSuffix = titleSuffix
        self.path = path
        self.offset = offset
        self.total = total
        self.sha256 = sha256
    }
}

/// One message from the phone about notes, with what the message itself says.
public struct NotesReply {
    public var type: String
    public var payload: NotesPayload
    public var ok: Bool
    public var reason: String?
    /// A piece of a picture or file, for `notes-asset-get`.
    public var data: Data?

    public init(type: String, payload: NotesPayload, ok: Bool, reason: String?, data: Data?) {
        self.type = type
        self.payload = payload
        self.ok = ok
        self.reason = reason
        self.data = data
    }
}
