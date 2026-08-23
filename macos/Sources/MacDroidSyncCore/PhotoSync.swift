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
        skipped: Int? = nil
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
    }
}

// MARK: - The window

public enum PhotoWindow {
    /// The lower bound of the sync window, in milliseconds since 1970.
    ///
    /// Both settings are lower bounds - "nothing older than this date" and
    /// "nothing older than this many days" - so the effective bound is the
    /// **later** of the two. That is what makes the day count a fuse: a start
    /// date set to 2005 cannot on its own open the floodgates.
    public static func effectiveFrom(startDate: Date?, lastDays: Int, now: Date) -> Int64 {
        // A day count of zero or less would mean "everything", which is never
        // what the setting is for; one day is the tightest honest reading.
        let days = max(1, lastDays)
        let byDays = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let byDate = startDate?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        return Int64((max(byDays, byDate) * 1000).rounded())
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

    public init(
        key: String,
        sha256: String,
        size: Int64,
        captureAt: Int64,
        localIdentifier: String?,
        state: PhotoIndexState,
        importedAt: Int64
    ) {
        self.key = key
        self.sha256 = sha256
        self.size = size
        self.captureAt = captureAt
        self.localIdentifier = localIdentifier
        self.state = state
        self.importedAt = importedAt
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
    public var approvalItems: Int
    public var approvalBytes: Int64
    /// How much one approved cycle may move.
    public var itemsPerCycle: Int
    public var bytesPerCycle: Int64

    public init(
        approvalItems: Int = 200,
        approvalBytes: Int64 = 2 * 1024 * 1024 * 1024,
        itemsPerCycle: Int = 200,
        bytesPerCycle: Int64 = 2 * 1024 * 1024 * 1024
    ) {
        self.approvalItems = approvalItems
        self.approvalBytes = approvalBytes
        self.itemsPerCycle = itemsPerCycle
        self.bytesPerCycle = bytesPerCycle
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
        limits: PhotoSyncLimits = PhotoSyncLimits(),
        isFirstRun: Bool
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
                plan.excluded.append(item)
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
            case .removedByUser:
                // Deliberately nothing: the user's deletion here outranks the
                // phone, and that holds for edited bytes too.
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
            case .imported:
                if !unchanged(item, entry) { plan.want.append(item) }
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
            for: plan.want, limits: limits, isFirstRun: isFirstRun
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
        limits: PhotoSyncLimits,
        isFirstRun: Bool
    ) -> String? {
        guard !want.isEmpty else { return nil }
        if isFirstRun {
            return "first run: nothing is imported before you have seen the report"
        }
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
