import Foundation

/// One row of the photo sync window: something the phone and this Mac disagree
/// about, described well enough for a person to decide what to do with it.
///
/// Pure, like `PhotoSync.swift` and for the same reason - this is the list the
/// destructive half of the feature is driven from, so it has to be testable
/// without PhotoKit, without disk and without a clock.

// MARK: - What a row is

/// What would happen to this file if the operator pressed Synchronise.
public enum PhotoActionKind: String, Codable, Equatable {
    /// Not here yet.
    case add
    /// Here, but the phone holds different bytes under the same key.
    case change
    /// Gone from the phone; the asset here is waiting to be taken out of Photos.
    case delete
    /// The phone listed it and will not send it. Nothing to synchronise; the
    /// only decision available is to stop being asked.
    case problem
}

/// Why a row is worth a second look. Separate from `kind` on purpose: a refused
/// bulk deletion is still a deletion, it just deserves the red.
public enum PhotoActionIssue: String, Codable, Equatable {
    case excludedSize
    case excludedUnreadable
    case excludedNoLocation
    case excludedNoDate
    /// From `PhotoPlan.refusedDelete`: more deletions at once than this Mac
    /// would expect, so they are shown but never done quietly.
    case bulkDeleteGuard
    /// The old copy of a photo the phone has edited. It is a removal like any
    /// other, but for a completely different reason - and one the operator has
    /// to be able to tell apart, because "the phone deleted this" and "this is
    /// last week's version of a photo you still have" call for opposite answers.
    case replacedVersion

    public init?(_ exclusion: PhotoExclusion) {
        switch exclusion {
        case .size: self = .excludedSize
        case .unreadable: self = .excludedUnreadable
        case .noLocation: self = .excludedNoLocation
        case .noDate: self = .excludedNoDate
        }
    }

    /// Short enough to read in a table column; the whole of it is in the tooltip.
    public var summary: String {
        switch self {
        case .excludedSize: return "too large to send"
        case .excludedUnreadable: return "the phone could not read it"
        case .excludedNoLocation: return "its location could not be read"
        case .excludedNoDate: return "no date could be established"
        case .bulkDeleteGuard: return "one of an unusually large batch"
        case .replacedVersion: return "the older copy, replaced by an edit on the phone"
        }
    }
}

public struct PhotoPendingAction: Codable, Equatable {
    /// The phone's key, and the identity of this row everywhere else: it is what
    /// `synchronize(keys:)` and `ignore(keys:)` take.
    public var key: String
    public var kind: PhotoActionKind
    /// The last path component, for reading.
    public var name: String
    public var size: Int64
    /// Nil for a row known only from the index, where no capture time was kept.
    public var captureAt: Int64?
    public var issue: PhotoActionIssue?
    /// The manifest item, kept whole.
    ///
    /// This is what makes the list survive a restart: the bytes have not arrived
    /// yet, so without this the Mac would know a decision is pending but not
    /// what to ask the phone for, and would have to wait for a fresh manifest.
    public var item: PhotoItem?
    /// When this row first stood in front of the operator. Used to notify once
    /// rather than once per cycle.
    public var noticedAt: Int64

    public init(
        key: String,
        kind: PhotoActionKind,
        name: String,
        size: Int64,
        captureAt: Int64?,
        issue: PhotoActionIssue? = nil,
        item: PhotoItem? = nil,
        noticedAt: Int64
    ) {
        self.key = key
        self.kind = kind
        self.name = name
        self.size = size
        self.captureAt = captureAt
        self.issue = issue
        self.item = item
        self.noticedAt = noticedAt
    }

    /// Whether Synchronise can do anything at all with this row. A `problem` is
    /// the phone's refusal, and no click here changes it.
    public var isSynchronizable: Bool { kind != .problem }

    /// Sorting rank: what needs attention first, what usually goes in bulk last.
    public var rank: Int {
        switch kind {
        case .problem: return 0
        case .delete: return 1
        case .change: return 2
        case .add: return 3
        }
    }

    /// How a replaced version is marked in its key. One definition, used by the
    /// importer that writes it and by everything that reads it back.
    public static let replacedMarker = "#replaced-"

    /// Whether this key belongs to the copy an edit replaced, rather than to a
    /// photo the phone no longer has.
    public static func isReplacedVersion(_ key: String) -> Bool {
        key.contains(replacedMarker)
    }

    /// The name to show. A replaced version carries a synthetic key so that the
    /// live key can belong to the new asset; the operator should still read the
    /// file's own name rather than that bookkeeping.
    public static func name(of key: String) -> String {
        let base = key.components(separatedBy: replacedMarker).first ?? key
        return (base as NSString).lastPathComponent
    }
}

// MARK: - Turning a plan into rows

public extension PhotoPlan {

    /// Every row the operator will see for this plan.
    ///
    /// Renames are deliberately absent: they are carried out as soon as they are
    /// noticed, they move no bytes and they delete nothing, so listing one as
    /// "waiting for a decision" would be describing work that is already done.
    ///
    /// `index` is needed because `want` mixes two different questions: a key the
    /// Mac has never held is an addition, while a key it holds under different
    /// bytes is a change, and only the index can tell them apart. The rule here
    /// mirrors `PhotoDelta.plan` exactly - if the two ever disagree, the window
    /// is lying about what the button will do.
    func pendingActions(index: [PhotoIndexEntry], now: Int64) -> [PhotoPendingAction] {
        let byKey = Dictionary(index.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [PhotoPendingAction] = []

        for item in want {
            let kind: PhotoActionKind
            switch byKey[item.key]?.state {
            case .none, .deletedByUs, .preexisting:
                // Nothing of it is here, so this is an arrival however often the
                // key has been seen before - including a row from the starting
                // point, which was only ever a note that the phone had it.
                kind = .add
            default:
                kind = .change
            }
            rows.append(
                PhotoPendingAction(
                    key: item.key,
                    kind: kind,
                    name: PhotoPendingAction.name(of: item.key),
                    size: item.size,
                    captureAt: item.captureAt,
                    item: item,
                    noticedAt: now
                )
            )
        }

        for entry in delete {
            rows.append(Self.deletion(entry, issue: Self.reason(for: entry), now: now))
        }
        for entry in refusedDelete {
            rows.append(Self.deletion(entry, issue: .bulkDeleteGuard, now: now))
        }

        for item in excluded {
            rows.append(
                PhotoPendingAction(
                    key: item.key,
                    kind: .problem,
                    name: PhotoPendingAction.name(of: item.key),
                    size: item.size,
                    captureAt: item.captureAt,
                    issue: item.excluded.flatMap(PhotoActionIssue.init) ?? .excludedUnreadable,
                    item: item,
                    noticedAt: now
                )
            )
        }

        return PhotoPendingAction.sorted(rows)
    }

    /// True when this plan does only the thing the feature exists for: bringing
    /// new photos in.
    ///
    /// Renames and cancelled deletions do not count against it - they are free,
    /// they touch no bytes and they contain no decision. Everything else does:
    /// a deletion, a replaced version, or an item the phone refused to send is
    /// exactly what the window is for.
    func isAdditionsOnly(index: [PhotoIndexEntry]) -> Bool {
        guard delete.isEmpty, refusedDelete.isEmpty, excluded.isEmpty else { return false }
        let byKey = Dictionary(index.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return want.allSatisfy { item in
            switch byKey[item.key]?.state {
            case .none, .deletedByUs, .preexisting: return true
            default: return false
            }
        }
    }

    /// Why this row is being offered for removal, when there is more to say than
    /// "the phone no longer has it".
    private static func reason(for entry: PhotoIndexEntry) -> PhotoActionIssue? {
        PhotoPendingAction.isReplacedVersion(entry.key) ? .replacedVersion : nil
    }

    private static func deletion(
        _ entry: PhotoIndexEntry, issue: PhotoActionIssue?, now: Int64
    ) -> PhotoPendingAction {
        PhotoPendingAction(
            key: entry.key,
            kind: .delete,
            name: PhotoPendingAction.name(of: entry.key),
            size: entry.size,
            captureAt: entry.captureAt,
            issue: issue,
            noticedAt: now
        )
    }
}

public extension PhotoPendingAction {

    /// Rows in one deterministic order: what needs attention on top, and each
    /// kind in one unbroken block so the window needs no group rows.
    static func sorted(_ rows: [PhotoPendingAction]) -> [PhotoPendingAction] {
        rows.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            let leftDate = left.captureAt ?? 0
            let rightDate = right.captureAt ?? 0
            if leftDate != rightDate { return leftDate > rightDate }
            return left.key < right.key
        }
    }

    /// Merges the plan's rows with the deletions already written down, keeping
    /// the moment each row was first noticed.
    ///
    /// The merge is not tidiness. `PhotoDelta.plan` only ever proposes deletions
    /// for `imported` rows, and writing one down moves it to `pendingDelete` -
    /// so a deletion appears in exactly one plan and never again. Without the
    /// waiting rows folded back in, deletions would flash into the window and
    /// vanish on the next cycle, which is precisely the case this window exists
    /// to handle.
    static func merge(
        _ fresh: [PhotoPendingAction], with existing: [PhotoPendingAction]
    ) -> [PhotoPendingAction] {
        let noticed = Dictionary(existing.map { ($0.key, $0.noticedAt) }, uniquingKeysWith: min)
        var seen = Set<String>()
        var merged: [PhotoPendingAction] = []
        for var row in fresh where seen.insert(row.key).inserted {
            if let first = noticed[row.key] { row.noticedAt = min(row.noticedAt, first) }
            merged.append(row)
        }
        return sorted(merged)
    }

    /// "3 to add, 2 to remove, 1 problem" - the one line above the table, and
    /// the body of the notification.
    static func summary(of rows: [PhotoPendingAction]) -> String {
        let counts = [
            (rows.filter { $0.kind == .problem }.count, "problem", "problems"),
            (rows.filter { $0.kind == .delete }.count, "to remove", "to remove"),
            (rows.filter { $0.kind == .change }.count, "to update", "to update"),
            (rows.filter { $0.kind == .add }.count, "to add", "to add"),
        ]
        let parts = counts
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? "nothing waiting" : parts.joined(separator: ", ")
    }
}
