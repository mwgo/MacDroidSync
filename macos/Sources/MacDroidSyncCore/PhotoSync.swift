import Foundation

/// The photo sync, as data and as one decision function.
///
/// Everything here is pure: no PhotoKit, no disk, no clock of its own. That is
/// deliberate, because this is where the destructive half of the feature is
/// decided, and a decision that cannot be tested cannot be trusted. The rules
/// that matter are written where they are enforced, not only in the docs.

// MARK: - What the phone says

/// Why an item is in the manifest but will never be fetched. It has to be
/// listed rather than left out: an item missing from the manifest reads as a
/// deletion, and a 2 GB video is not a deletion.
public enum PhotoExclusion: String, Codable, Equatable {
    /// Bigger than the agreed per-item limit.
    case size
    /// MediaStore would not open it.
    case unreadable
    /// The phone cannot read the original bytes, so the GPS tags would be
    /// stripped on the way out. Sending it would quietly lose data.
    case noLocation
    /// No capture date could be established, so it belongs to no window.
    case noDate
}

/// One item of one manifest page. The JSON keys are single letters because a
/// full library sends five thousand copies of this.
public struct PhotoItem: Codable, Equatable {
    public let key: String
    /// Capture time in milliseconds since 1970, never a modification time.
    public let captureAt: Int64
    public let size: Int64
    public let mime: String?
    /// Lowercase hex, and optional: the phone is allowed to run out of hashing
    /// budget, in which case size and capture time decide (see `PhotoDelta`).
    public let sha256: String?
    public let excluded: PhotoExclusion?

    enum CodingKeys: String, CodingKey {
        case key = "k", captureAt = "t", size = "s", mime = "m", sha256 = "h", excluded = "x"
    }

    public init(
        key: String,
        captureAt: Int64,
        size: Int64,
        mime: String? = nil,
        sha256: String? = nil,
        excluded: PhotoExclusion? = nil
    ) {
        self.key = key
        self.captureAt = captureAt
        self.size = size
        self.mime = mime
        self.sha256 = sha256
        self.excluded = excluded
    }

    /// Whether this item is a candidate for transfer at all.
    public var isFetchable: Bool { excluded == nil }
}

/// The `photo` field of a message: one page of a manifest, a pull request, or a
/// correction. One nested object rather than a dozen flat fields, because
/// `Message` is a single flat struct and every field there costs three edits on
/// each platform.
public struct PhotoPayload: Codable, Equatable {
    /// Set on `file-offer` to say "this is a gallery item, not a shared file".
    public var key: String?
    /// Identifies one snapshot across its pages.
    public var manifestId: String?
    /// 1...pages. Zero means a correction: apply `gone`, infer nothing.
    public var page: Int?
    public var pages: Int?
    /// Items across all pages, so the receiver can tell a complete snapshot
    /// from a truncated one.
    public var count: Int?
    /// The window's lower bound the phone actually applied, in milliseconds.
    /// The Mac uses this number and never recomputes it - see `PhotoDelta`.
    public var from: Int64?
    /// On `file-offer`: when this one item was taken. Not to be confused with
    /// `from`, which is a bound for a whole manifest - the index needs the item's
    /// own time, because that is what scopes deletions later.
    public var captureAt: Int64?
    public var items: [PhotoItem]?
    /// Keys the phone knows are gone. Not bounded by the window.
    public var gone: [String]?
    /// On `photo-pull`: what to send. Absent means "build a manifest now".
    public var keys: [String]?
    /// Items the phone could not place in time, for the report.
    public var skipped: Int?
    /// On `photo-config`: whether the phone describes its camera folder at all.
    ///
    /// These three carry the settings that used to live on the phone. They are
    /// deliberately plain booleans and numbers: `PhotoExclusion` decodes
    /// strictly, so a value the other side does not recognise would throw and
    /// take the session with it. A new field must never be an enum until that
    /// changes.
    public var enabled: Bool?
    /// How many days back the phone should look.
    public var lastDays: Int?
    /// The largest item worth starting. The phone may lower this, never raise it.
    public var maxItemBytes: Int64?

    public init(
        key: String? = nil,
        manifestId: String? = nil,
        page: Int? = nil,
        pages: Int? = nil,
        count: Int? = nil,
        from: Int64? = nil,
        captureAt: Int64? = nil,
        items: [PhotoItem]? = nil,
        gone: [String]? = nil,
        keys: [String]? = nil,
        skipped: Int? = nil,
        enabled: Bool? = nil,
        lastDays: Int? = nil,
        maxItemBytes: Int64? = nil
    ) {
        self.key = key
        self.manifestId = manifestId
        self.page = page
        self.pages = pages
        self.count = count
        self.from = from
        self.captureAt = captureAt
        self.items = items
        self.gone = gone
        self.keys = keys
        self.skipped = skipped
        self.enabled = enabled
        self.lastDays = lastDays
        self.maxItemBytes = maxItemBytes
    }
}

// MARK: - What the Mac knows

public enum PhotoIndexState: String, Codable, Equatable {
    /// In the Photos library, as far as we know.
    case imported
    /// The phone no longer has it. Waiting for the operator to confirm removal;
    /// nothing is ever deleted from Photos without that click.
    case pendingDelete
    /// The asset stopped resolving and no tombstone explained it, so the user
    /// deleted it in Photos. Sticky: this is what stops the sync from putting
    /// back what somebody deliberately threw away.
    case removedByUser
    /// We removed it from Photos because the phone had removed it. Deliberately
    /// *not* sticky, and that is the difference from `removedByUser`: nobody
    /// rejected this photo here, so if it reappears on the phone - restored from
    /// the phone's own bin, say - it is welcome back.
    case deletedByUs
    /// The operator ignored this in the photo sync window. Sticky, exactly like
    /// `removedByUser` and for the same reason: a decision taken here outranks
    /// whatever the phone says about it afterwards.
    case ignoredByUser
    /// It was on the phone before this Mac started looking. Not fetched, not
    /// deleted and not reported: the starting point changes are counted from.
    ///
    /// Kept apart from `ignoredByUser` because the two differ where it matters.
    /// Nobody refused this photo, so a later *edit* of it is ordinary work and
    /// is fetched; and calling five thousand of these "ignored" in the report
    /// would be a plain lie about what the operator did.
    case preexisting

    /// The states where this Mac already has an answer for a key and does not
    /// need to put the question in front of anybody again.
    public var isSettled: Bool {
        self == .removedByUser || self == .ignoredByUser || self == .preexisting
    }

    /// An unknown state is read as the most cautious thing this file can say.
    ///
    /// Without this, a single row written by a newer build makes the decode of
    /// the *whole* array throw, `PhotoIndexStore.load` reads that as "start
    /// empty", and every "never again" recorded here is forgotten - the feature
    /// then re-imports the lot. Falling back to `removedByUser` means neither
    /// fetch nor delete: only `imported` rows are ever deletion candidates.
    /// (An older build reading a `preexisting` row lands here too, which is the
    /// right side to fail on: it shows in the wrong counter and does nothing.)
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhotoIndexState(rawValue: raw) ?? .removedByUser
    }
}

/// One row of `photos-index.json`: what the Mac has, keyed by the phone's key.
public struct PhotoIndexEntry: Codable, Equatable {
    public var key: String
    /// The bytes we hold, so a changed photo can be recognised.
    public var sha256: String
    public var size: Int64
    public var captureAt: Int64
    /// The Photos asset. Nil only between staging and a verified import.
    public var localIdentifier: String?
    public var state: PhotoIndexState
    public var importedAt: Int64
    /// The version of this photo the operator refused in the sync window.
    ///
    /// Optional on purpose, and not merely for tidiness: the compiler
    /// synthesises `decodeIfPresent` for an optional, so an index written before
    /// this field existed still loads. A non-optional with a default value would
    /// throw instead, and the store reads a throw as "start from empty".
    ///
    /// Ignoring an *edit* is recorded here rather than by moving the row to
    /// `ignoredByUser`, because that would take the row out of the `imported`
    /// set - and that set is what notices the photo later leaving the phone.
    public var ignoredVersion: String?

    public init(
        key: String,
        sha256: String,
        size: Int64,
        captureAt: Int64,
        localIdentifier: String?,
        state: PhotoIndexState,
        importedAt: Int64,
        ignoredVersion: String? = nil
    ) {
        self.key = key
        self.sha256 = sha256
        self.size = size
        self.captureAt = captureAt
        self.localIdentifier = localIdentifier
        self.state = state
        self.importedAt = importedAt
        self.ignoredVersion = ignoredVersion
    }

    /// How a refused version is recognised when it comes round again.
    ///
    /// The hash when there is one, and otherwise size and capture time - which
    /// is exactly what `PhotoDelta.unchanged` falls back to when the phone has
    /// run out of hashing budget. Recording anything else would mean an ignored
    /// edit came back on the next cycle whenever the phone was busy.
    public static func fingerprint(of item: PhotoItem) -> String {
        if let hash = item.sha256 { return hash.lowercased() }
        return "s\(item.size):t\(item.captureAt)"
    }

    /// Whether this is the exact version the operator refused for this key.
    /// A later, *different* edit is a new question and is not covered by this.
    public func refuses(_ item: PhotoItem) -> Bool {
        guard let ignored = ignoredVersion else { return false }
        return Self.fingerprint(of: item) == ignored
    }

    /// The same question from the transfer path, which knows only a hash.
    public func refuses(sha256: String?) -> Bool {
        guard let sha256, let ignored = ignoredVersion else { return false }
        return sha256.lowercased() == ignored
    }
}

// MARK: - The plan

/// A key that moved: same bytes, new name. Worth its own case because the naive
/// reading is "delete the asset and download the file again", which for a 3 GB
/// video costs 3 GB and destroys the asset for nothing.
public struct PhotoRename: Equatable {
    public let from: String
    public let to: String
}

public struct PhotoSyncLimits: Equatable {
    /// Above either of these, the cycle stops and waits for the operator.
    ///
    /// Set low on purpose. What runs unattended should be an ordinary day's
    /// photos - a handful from a walk, a couple of short clips - and anything
    /// beyond that is worth a glance before it moves, because the list is also
    /// where deletions and replaced versions turn up. Twenty items or two
    /// hundred megabytes is roughly the line between "the feature working" and
    /// "something happened that I should know about".
    public var approvalItems: Int
    public var approvalBytes: Int64
    /// How much one approved cycle may move. Deliberately far larger than the
    /// approval limits: once the operator has said yes to a backlog, the point
    /// is to drain it, not to make them say yes again every twenty photos.
    public var itemsPerCycle: Int
    public var bytesPerCycle: Int64

    public init(
        approvalItems: Int = 20,
        approvalBytes: Int64 = 200 * 1024 * 1024,
        itemsPerCycle: Int = 200,
        bytesPerCycle: Int64 = 2 * 1024 * 1024 * 1024
    ) {
        self.approvalItems = approvalItems
        self.approvalBytes = approvalBytes
        self.itemsPerCycle = itemsPerCycle
        self.bytesPerCycle = bytesPerCycle
    }
}

/// The settings this Mac now owns, and the range each one is honest in.
///
/// One place, because each is enforced in three: the field in the settings
/// window, the property in `Settings`, and the message that carries it to the
/// phone. Plain functions rather than logic inside the properties, so the
/// clamping can be tested without `UserDefaults` and without a singleton.
public enum PhotoSyncSettings {

    public static let days = 1...3650
    public static let defaultDays = 30
    public static let intervalMinutes = 5...1440
    public static let defaultIntervalMinutes = 30
    public static let maxItemMB = 1...2048
    public static let defaultMaxItemMB = 2048
    public static let defaultAlbumName = "MacDroidSync"

    /// Zero means the key has never been written - `UserDefaults.integer`
    /// cannot tell that from a real zero, and zero is not a sane value for any
    /// of these - so it reads as the default rather than as "nothing".
    public static func days(from stored: Int) -> Int {
        stored == 0 ? defaultDays : min(max(stored, days.lowerBound), days.upperBound)
    }

    public static func intervalMinutes(from stored: Int) -> Int {
        stored == 0
            ? defaultIntervalMinutes
            : min(max(stored, intervalMinutes.lowerBound), intervalMinutes.upperBound)
    }

    public static func maxItemMB(from stored: Int) -> Int {
        stored == 0 ? defaultMaxItemMB : min(max(stored, maxItemMB.lowerBound), maxItemMB.upperBound)
    }

    /// A blank name is the default rather than an error: there is no sensible
    /// reading of "no album" here, and refusing to save would be worse.
    public static func albumName(from stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultAlbumName : trimmed
    }
}

public struct PhotoPlan: Equatable {
    /// To fetch, newest first.
    public var want: [PhotoItem] = []
    /// Assets to take out of Photos, once the operator says so.
    public var delete: [PhotoIndexEntry] = []
    /// Key rewrites: no bytes, no deletions.
    public var renames: [PhotoRename] = []
    /// Listed by the phone, never fetched. Goes into the report.
    public var excluded: [PhotoItem] = []
    /// Deletions the ratio guard would not allow. Reported, not performed.
    public var refusedDelete: [PhotoIndexEntry] = []
    /// Keys that came back (restored from the phone's bin): drop the pending
    /// deletion instead of deleting and re-importing the same bytes.
    public var cancelPendingDelete: [String] = []
    /// True when nothing may move until the operator approves this plan.
    public var needsApproval: Bool = false
    /// Why approval is needed, for the report.
    public var approvalReason: String?

    public var wantBytes: Int64 { want.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool {
        want.isEmpty && delete.isEmpty && renames.isEmpty && cancelPendingDelete.isEmpty
    }
}

public enum PhotoDelta {

    /// Turns a complete manifest plus what the Mac already has into a plan.
    ///
    /// Two invariants hold whatever the inputs look like, and the tests exist to
    /// keep them holding:
    ///
    /// 1. **Only what the phone declared can be deleted.** Deletion candidates
    ///    are scoped by `manifest.from`, the bound the *phone* applied, never by
    ///    a bound computed here. An item that has aged out of the window has
    ///    `captureAt < from` and is therefore invisible to the delete rule - the
    ///    "old photos must not vanish from the Mac" requirement falls out of the
    ///    arithmetic instead of needing a special case.
    /// 2. **What the user deleted in Photos stays deleted.** A `removedByUser`
    ///    row is never wanted again, not even when the phone edits the photo.
    ///
    /// `tombstones` are handled separately from absence on purpose: they are an
    /// assertion by the phone and are *not* window-scoped, which is the only way
    /// a deletion of last year's photo can reach the Mac at all.
    public static func plan(
        items: [PhotoItem],
        from: Int64,
        tombstones: [String] = [],
        index: [PhotoIndexEntry],
        limits: PhotoSyncLimits = PhotoSyncLimits()
    ) -> PhotoPlan {
        var plan = PhotoPlan()
        let byKey = Dictionary(index.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let manifestKeys = Set(items.map(\.key))

        // Live bytes we hold, for spotting a rename by content.
        var liveByHash: [String: PhotoIndexEntry] = [:]
        for entry in index where entry.state == .imported {
            liveByHash[entry.sha256] = entry
        }

        // 1. What to fetch, and what a changed hash means.
        for item in items {
            guard item.isFetchable else {
                // Not reported once the operator has refused it. Without this an
                // item the phone will never send - one photo with no location,
                // say - would park every cycle for the rest of time.
                if byKey[item.key]?.state.isSettled != true {
                    plan.excluded.append(item)
                }
                continue
            }
            guard let entry = byKey[item.key] else {
                // A new key holding bytes we already have is a rename, not a
                // download - but only when the old key is really gone from the
                // manifest, otherwise it is a genuine copy of the same photo.
                if let hash = item.sha256,
                   let moved = liveByHash[hash],
                   !manifestKeys.contains(moved.key) {
                    plan.renames.append(PhotoRename(from: moved.key, to: item.key))
                } else {
                    plan.want.append(item)
                }
                continue
            }
            switch entry.state {
            case .removedByUser, .ignoredByUser:
                // Deliberately nothing: a decision taken on this Mac outranks
                // the phone, and that holds for edited bytes too.
                continue
            case .pendingDelete:
                // It is back. Restoring from the phone's bin must not cost a
                // deletion and a re-download.
                if unchanged(item, entry) {
                    plan.cancelPendingDelete.append(entry.key)
                } else {
                    plan.want.append(item)
                }
            case .deletedByUs:
                // We took it out because the phone had; it is back, so fetch it.
                // Nothing of it is left here, so the hash cannot be compared.
                plan.want.append(item)
            case .imported, .preexisting:
                // A refused edit is not wanted; a *different* later edit is,
                // because that is a question nobody has answered yet. A row from
                // the starting point behaves the same way: it was here before we
                // began, so only a later edit of it is work.
                if !unchanged(item, entry), !entry.refuses(item) {
                    plan.want.append(item)
                }
            }
        }

        // 2. Deletions. Tombstones are assertions; absence is an inference, and
        //    the inference is scoped by the phone's own bound.
        let renamedAway = Set(plan.renames.map(\.from))
        let tombstoned = Set(tombstones)
        var candidates: [PhotoIndexEntry] = []
        var inWindow = 0
        for entry in index where entry.state == .imported {
            if entry.captureAt >= from { inWindow += 1 }
            guard !renamedAway.contains(entry.key) else { continue }
            if tombstoned.contains(entry.key) {
                candidates.append(entry)
            } else if entry.captureAt >= from, !manifestKeys.contains(entry.key) {
                candidates.append(entry)
            }
        }

        // 3. The ratio guard. A bulk delete on the phone is rare; a bug here is
        //    unrecoverable, so past a threshold it is reported and not done.
        let allowed = max(20, inWindow / 10)
        if candidates.count > allowed {
            plan.refusedDelete = candidates
        } else {
            plan.delete = candidates
        }

        // 4. Newest first, so an approved backlog delivers the useful photos
        //    before the archive.
        plan.want.sort { $0.captureAt > $1.captureAt }

        // 5. The approval gate.
        plan.approvalReason = approvalReason(
            for: plan.want, limits: limits
        )
        plan.needsApproval = plan.approvalReason != nil
        return plan
    }

    /// Why this batch may not move without the operator, or nil when it may.
    ///
    /// Kept separate from `plan` because the caller has to ask the same question
    /// again about a *part* of a plan: keys the operator already approved are
    /// past this gate, while anything that turned up afterwards is not.
    public static func approvalReason(
        for want: [PhotoItem],
        limits: PhotoSyncLimits
    ) -> String? {
        guard !want.isEmpty else { return nil }
        if want.count > limits.approvalItems {
            return "\(want.count) items is more than the \(limits.approvalItems) "
                + "this Mac imports without asking"
        }
        let total = want.reduce(0) { $0 + $1.size }
        if total > limits.approvalBytes {
            return "\(bytes(total)) is more than the \(bytes(limits.approvalBytes)) "
                + "this Mac imports without asking"
        }
        return nil
    }

    /// Same bytes as we hold. The hash decides when the phone sent one; size is
    /// the fallback when it ran out of hashing budget, and capture time guards
    /// against two different photos of the same length.
    private static func unchanged(_ item: PhotoItem, _ entry: PhotoIndexEntry) -> Bool {
        if let hash = item.sha256 { return hash.lowercased() == entry.sha256.lowercased() }
        return item.size == entry.size && item.captureAt == entry.captureAt
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
