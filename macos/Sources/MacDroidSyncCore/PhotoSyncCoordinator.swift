import Foundation

/// One item the phone listed but will not send, kept for the report so that
/// "it did not arrive" is never left without an explanation.
public struct PhotoSkipped: Codable, Equatable {
    public let name: String
    public let size: Int64
    public let reason: PhotoExclusion

    public init(name: String, size: Int64, reason: PhotoExclusion) {
        self.name = name
        self.size = size
        self.reason = reason
    }
}

/// What survives a restart between cycles: the rows waiting for the operator,
/// what the operator has already approved, and the last report.
public struct PhotoSyncState: Codable, Equatable {
    /// Everything standing in front of the operator, whatever kind it is.
    ///
    /// The rows carry their manifest items, so a decision taken after a restart
    /// can be acted on straight away rather than waiting for a fresh manifest.
    public var pending: [PhotoPendingAction] = []
    /// Why the cycle stopped, when there is something worth saying beyond the
    /// list itself - the size gate, or the first run.
    public var pendingReason: String?
    /// Exactly the keys the operator saw and approved - not a general licence.
    public var approvedKeys: [String] = []
    /// Whether the first-run report has been seen and accepted.
    ///
    /// This has to be remembered here rather than inferred from an empty index,
    /// and the reason is a loop: the gate's condition would be cleared by an
    /// import, and the gate is what stops the import. So the operator's click is
    /// the thing that opens it, once.
    public var approvedFirstRun: Bool = false
    /// Keys the operator has already been told about. Without this the same
    /// list would raise a banner on every cycle, twice an hour, for ever.
    public var notifiedKeys: [String] = []
    public var skipped: [PhotoSkipped] = []
    public var lastCycleAt: Int64?
    public var windowFrom: Int64?

    public init() {}

    /// The rows that will cost bytes if they are approved.
    public var awaitingTransfer: [PhotoPendingAction] {
        pending.filter { $0.kind == .add || $0.kind == .change }
    }
    public var awaitingBytes: Int64 { awaitingTransfer.reduce(0) { $0 + $1.size } }

    enum CodingKeys: String, CodingKey {
        case pending, pendingReason, approvedKeys, approvedFirstRun, notifiedKeys
        case skipped, lastCycleAt, windowFrom
    }

    /// Keys written by the build that had no sync window. Read, never written.
    private enum LegacyKeys: String, CodingKey {
        case awaitingApproval, approvalReason
    }

    /// Written by hand rather than synthesised, and that is load-bearing.
    ///
    /// The synthesised `Decodable` does not fall back to a property's default
    /// value when its key is absent - it throws. `PhotoSyncStateStore.load`
    /// reads any throw as "start from an empty state", so simply adding a field
    /// to the synthesised version would quietly discard `approvedKeys` and
    /// `approvedFirstRun` for everybody who already has a file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = try container.decodeIfPresent([PhotoPendingAction].self, forKey: .pending) ?? []
        pendingReason = try container.decodeIfPresent(String.self, forKey: .pendingReason)
        approvedKeys = try container.decodeIfPresent([String].self, forKey: .approvedKeys) ?? []
        approvedFirstRun = try container.decodeIfPresent(Bool.self, forKey: .approvedFirstRun) ?? false
        notifiedKeys = try container.decodeIfPresent([String].self, forKey: .notifiedKeys) ?? []
        skipped = try container.decodeIfPresent([PhotoSkipped].self, forKey: .skipped) ?? []
        lastCycleAt = try container.decodeIfPresent(Int64.self, forKey: .lastCycleAt)
        windowFrom = try container.decodeIfPresent(Int64.self, forKey: .windowFrom)

        // A plan parked by the previous build. The same items, now as rows, so
        // an upgrade does not lose a decision the operator was already facing.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let items = try legacy.decodeIfPresent([PhotoItem].self, forKey: .awaitingApproval) ?? []
        if !items.isEmpty {
            pending += items.map {
                PhotoPendingAction(
                    key: $0.key,
                    kind: .add,
                    name: PhotoPendingAction.name(of: $0.key),
                    size: $0.size,
                    captureAt: $0.captureAt,
                    item: $0,
                    noticedAt: 0
                )
            }
            let legacyReason = try legacy.decodeIfPresent(String.self, forKey: .approvalReason)
            pendingReason = pendingReason ?? legacyReason
        }
    }
}

/// What one press of Synchronise actually did.
public struct PhotoActionOutcome: Equatable {
    /// Additions and changes asked of the phone.
    public var requested: Int = 0
    /// Assets that left Photos.
    public var deleted: Int = 0
    /// The system alert was dismissed. Nothing left the library.
    public var cancelledByUser = false
    public var failure: String?
    /// Rows that stayed on the list because the phone could not be reached.
    public var notSent: Int = 0

    public init() {}
}

/// `photos-state.json`, in the same shape as every other store here.
public final class PhotoSyncStateStore {

    private let url: URL
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-state")
    private var state: PhotoSyncState

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("photos-state.json")
        self.state = Self.load(from: self.url)
    }

    public var current: PhotoSyncState { queue.sync { state } }

    public func update(_ change: (inout PhotoSyncState) -> Void) {
        queue.sync {
            change(&state)
            persist()
        }
    }

    private func persist() {
        if state == PhotoSyncState() {
            try? FileManager.default.removeItem(at: url)
            return
        }
        AppPaths.ensureSupportDirectory()
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            Log.error("Could not save the photo sync state: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> PhotoSyncState {
        guard let data = try? Data(contentsOf: url) else { return PhotoSyncState() }
        guard let state = try? JSONDecoder().decode(PhotoSyncState.self, from: data) else {
            Log.error("The photo sync state is unreadable; starting from an empty one")
            return PhotoSyncState()
        }
        return state
    }
}

/// What the menu and the settings tab show.
public struct PhotoSyncReport: Equatable {
    public var imported: Int = 0
    /// Rows waiting in the sync window, of every kind.
    public var pendingDecisions: Int = 0
    /// Why the cycle stopped, when there is more to say than the list itself.
    public var pendingReason: String?
    /// Of those rows, the ones that would cost bytes.
    public var awaitingApproval: Int = 0
    public var awaitingBytes: Int64 = 0
    /// Assets written down as gone from the phone. Nothing leaves the library
    /// before the operator says so in the window.
    public var pendingDeletions: Int = 0
    public var removedByUser: Int = 0
    public var ignored: Int = 0
    public var skipped: [PhotoSkipped] = []
    public var lastCycleAt: Date?
    public var windowFrom: Date?
    /// Set when the last thing the phone said was a refusal, so a feature that
    /// is doing nothing always says why.
    public var refusal: String?

    public init() {}
}

/// Drives one photo sync cycle: manifest in, plan out, and nothing at all until
/// the operator has decided about anything that is not a plain addition.
///
/// The gate is the point of this type. A plan either only brings new photos in,
/// which is the feature working, or it stops here and waits in the sync window -
/// and while it is stopped, not one offer goes on the wire.
public final class PhotoSyncCoordinator {

    private let importer: PhotoImporter
    private let assembler: PhotoManifestAssembler
    private let state: PhotoSyncStateStore
    private let limits: PhotoSyncLimits
    private let approvesAdditions: () -> Bool
    private let request: ([String]?, String?) -> Bool
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-coordinator")
    private var refusal: String?

    /// Fires whenever anything the UI shows has changed.
    public var onReport: ((PhotoSyncReport) -> Void)?
    /// Fires with the whole list whenever it changes.
    public var onPendingChanged: (([PhotoPendingAction]) -> Void)?
    /// Fires only with rows the operator has never been shown, so that whoever
    /// posts a notification cannot turn a standing list into a standing alarm.
    public var onDecisionsNeeded: (([PhotoPendingAction]) -> Void)?

    public init(
        importer: PhotoImporter,
        state: PhotoSyncStateStore = PhotoSyncStateStore(),
        assembler: PhotoManifestAssembler = PhotoManifestAssembler(),
        limits: PhotoSyncLimits = PhotoSyncLimits(),
        approvesAdditions: @escaping () -> Bool = { false },
        request: @escaping ([String]?, String?) -> Bool
    ) {
        self.importer = importer
        self.state = state
        self.assembler = assembler
        self.limits = limits
        self.approvesAdditions = approvesAdditions
        self.request = request
    }

    // MARK: - What the operator does

    /// "Sync photos now": asks for a fresh manifest, whatever the interval says.
    public func syncNow() {
        refusal = nil
        _ = request(nil, nil)
    }

    /// Everything waiting for a decision.
    public var pendingActions: [PhotoPendingAction] { state.current.pending }

    /// Carries out exactly the rows the operator picked.
    ///
    /// Deletions go first and go together: macOS puts one confirmation alert in
    /// front of a batch, and keeping that to one alert is the whole reason
    /// removal was never automatic. Whatever is not picked stays on the list.
    @discardableResult
    public func synchronize(keys: [String]) -> PhotoActionOutcome {
        queue.sync {
            let picked = Set(keys)
            var outcome = PhotoActionOutcome()
            let rows = state.current.pending.filter { picked.contains($0.key) }
            guard !rows.isEmpty else { return outcome }

            var done = Set<String>()

            let deletions = Set(rows.filter { $0.kind == .delete }.map(\.key))
            if !deletions.isEmpty {
                switch importer.flushDeletions(keys: deletions) {
                case .deleted(let removed):
                    outcome.deleted = removed.count
                case .cancelledByUser:
                    outcome.cancelledByUser = true
                case .failed(let why):
                    outcome.failure = why
                case .nothingToDo:
                    break
                }
                // What is still written down as waiting is what did not go. The
                // index is the truth here, not the outcome: a row the user had
                // already deleted by hand is done without appearing in either.
                let stillWaiting = Set(importer.waitingDeletions.map(\.key))
                done.formUnion(deletions.subtracting(stillWaiting))
            }

            let transfers = rows.filter { $0.kind == .add || $0.kind == .change }
            let items = transfers.compactMap(\.item)
            if !items.isEmpty {
                // Approved keys are recorded before asking, so that a batch cut
                // short by the per-cycle limits drains over the cycles that
                // follow instead of needing another click.
                state.update { snapshot in
                    snapshot.approvedKeys = Array(Set(snapshot.approvedKeys).union(items.map(\.key)))
                    snapshot.approvedFirstRun = true
                }
                let asked = fetch(items)
                if asked > 0 {
                    outcome.requested = asked
                    done.formUnion(transfers.map(\.key))
                } else {
                    outcome.notSent = transfers.count
                }
            }

            if rows.contains(where: { $0.kind == .problem }) {
                // The phone will not send these, so there is nothing to carry
                // out. They stay on the list until they are ignored.
                Log.info("\(rows.filter { $0.kind == .problem }.count) item(s) cannot be "
                    + "transferred; the phone will not send them")
            }

            drop(done)
            publish()
            return outcome
        }
    }

    /// The operator does not want to be asked about these again, ever.
    ///
    /// Nothing is deleted here, and that is worth being explicit about: ignoring
    /// a pending removal means the asset *stays* in Photos and the question
    /// stops coming back.
    public func ignore(keys: [String]) {
        queue.sync {
            let picked = Set(keys)
            let rows = state.current.pending.filter { picked.contains($0.key) }
            guard !rows.isEmpty else { return }

            var decisions: [PhotoIgnore] = []
            for row in rows {
                switch row.kind {
                case .add, .problem:
                    guard let item = row.item else { continue }
                    decisions.append(.never(item))
                case .change:
                    guard let item = row.item else { continue }
                    decisions.append(.version(key: row.key, item: item))
                case .delete:
                    decisions.append(.keepInPhotos(key: row.key))
                }
            }
            importer.ignore(decisions)
            state.update { $0.approvedFirstRun = true }
            forget(picked)
            publish()
        }
    }

    // MARK: - What the phone says

    public func handle(manifest payload: PhotoPayload, ok: Bool, reason: String?) {
        switch assembler.accept(payload, ok: ok, reason: reason) {
        case .rejected(let why):
            // The phone will not vouch for its own picture, so this Mac does
            // nothing at all - no fetching, and above all no deleting.
            refusal = why
            Log.info("The phone would not describe its camera folder: \(why)")
            publish()
        case .incomplete(let received, let total):
            Log.debug("Photo manifest still arriving, \(received) of \(total) items")
        case .correction(let gone):
            // A key that went away between the manifest and the transfer. Written
            // down like any other deletion, and removed when asked.
            guard !gone.isEmpty else { return }
            importer.markGone(gone)
            refreshPending()
            publish()
        case .complete(let snapshot):
            refusal = nil
            apply(snapshot)
        }
    }

    /// Called when the connection drops: a half-collected picture of the phone
    /// must not survive to be compared against later.
    public func connectionLost() {
        assembler.reset()
    }

    // MARK: - The cycle

    private func apply(_ snapshot: PhotoManifestAssembler.Snapshot) {
        let stored = state.current
        // The first-run gate is opened by the operator's click, not by the index:
        // see `approvedFirstRun`.
        let isFirstRun = importer.isFirstRun && !stored.approvedFirstRun
        let indexBefore = importer.indexedKeys
        let plan = PhotoDelta.plan(
            items: snapshot.items,
            from: snapshot.from,
            tombstones: snapshot.tombstones,
            index: indexBefore,
            limits: limits,
            isFirstRun: isFirstRun
        )

        // Renames first: they are free, and doing them before the delete step
        // keeps a moved file from being read as a deletion plus a download.
        for rename in plan.renames {
            importer.rename(from: rename.from, to: rename.to)
            Log.info("A photo was renamed on the phone; kept the one in Photos")
        }
        if !plan.cancelPendingDelete.isEmpty {
            importer.cancelPendingDeletion(plan.cancelPendingDelete)
        }
        // Written down, and that is all. Removal happens when the operator asks
        // for it in the sync window, because macOS puts a confirmation alert in
        // front of it - a dialog appearing by itself, up to twice an hour, is
        // not acceptable.
        if !plan.delete.isEmpty {
            importer.markGone(plan.delete.map(\.key))
        }
        if !plan.refusedDelete.isEmpty {
            // Marked like the rest - nothing happens without the operator anyway -
            // but said out loud, because a batch this size is more likely a fault
            // than real tidying up, and the window is where it will be judged.
            importer.markGone(plan.refusedDelete.map(\.key))
            Log.error("\(plan.refusedDelete.count) photos look deleted on the phone, which is more "
                + "than this Mac would expect. Check the count before removing them.")
        }

        let now = Message.now()
        let approved = Set(stored.approvedKeys)
        let approvedWant = plan.want.filter { approved.contains($0.key) }
        let freshWant = plan.want.filter { !approved.contains($0.key) }
        let gate = PhotoDelta.approvalReason(for: freshWant, limits: limits, isFirstRun: isFirstRun)

        // Deletions written down in an earlier cycle are still waiting: a
        // deletion appears in exactly one plan, because writing it down moves
        // the row out of the state deletions are computed from.
        let carried = carriedDeletions(now: now, existing: stored.pending)

        // The one question that decides whether this cycle runs by itself.
        let mustAsk = gate != nil
            || approvesAdditions()
            || !plan.isAdditionsOnly(index: indexBefore)
            || !carried.isEmpty

        var rows: [PhotoPendingAction] = []
        if mustAsk {
            rows = plan.pendingActions(index: indexBefore, now: now)
                .filter { !approved.contains($0.key) }
            rows = PhotoPendingAction.merge(rows + carried, with: stored.pending)
        }

        // An approved key keeps its approval until the bytes actually arrive.
        // Dropping it at the moment it was asked for would send it back through
        // the gate on the next cycle whenever a transfer had not finished, and
        // the operator would be asked to approve the same photo twice. Keys that
        // have left `want` are either here or gone, so they can go.
        let stillWanted = Set(plan.want.map(\.key))

        state.update { snapshot2 in
            snapshot2.approvedKeys = snapshot2.approvedKeys.filter { stillWanted.contains($0) }
            snapshot2.lastCycleAt = now
            snapshot2.windowFrom = snapshot.from
            snapshot2.skipped = plan.excluded.map {
                PhotoSkipped(name: PhotoPendingAction.name(of: $0.key),
                             size: $0.size,
                             reason: $0.excluded ?? .unreadable)
            }
            snapshot2.pending = rows
            snapshot2.pendingReason = rows.isEmpty ? nil : gate
            // Forget what was announced about rows that are no longer here, so
            // the same key turning up again is news again.
            let live = Set(rows.map(\.key))
            snapshot2.notifiedKeys = snapshot2.notifiedKeys.filter { live.contains($0) }
        }

        if mustAsk {
            let bytes = rows.reduce(Int64(0)) { $0 + $1.size }
            Log.info("Photo sync is waiting for you: \(rows.count) item(s), "
                + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                + (gate.map { " - \($0)" } ?? ""))
        }

        // Approved work still moves while something new waits for a decision.
        fetch(approvedWant + (mustAsk ? [] : freshWant))
        announce(rows)
        publish()
    }

    /// Rows for assets already written down as gone, so they keep their place in
    /// the window over the cycles that follow.
    private func carriedDeletions(
        now: Int64, existing: [PhotoPendingAction]
    ) -> [PhotoPendingAction] {
        importer.waitingDeletions.map { entry in
            PhotoPendingAction(
                key: entry.key,
                kind: .delete,
                name: PhotoPendingAction.name(of: entry.key),
                size: entry.size,
                captureAt: entry.captureAt,
                issue: existing.first { $0.key == entry.key }?.issue,
                noticedAt: now
            )
        }
    }

    /// Rebuilds the list from what the index now says, without a new manifest.
    private func refreshPending() {
        let stored = state.current
        let carried = carriedDeletions(now: Message.now(), existing: stored.pending)
        let kept = stored.pending.filter { $0.kind != .delete }
        let rows = PhotoPendingAction.merge(kept + carried, with: stored.pending)
        state.update { $0.pending = rows }
        announce(rows)
    }

    /// Takes decided rows off the list.
    ///
    /// Approvals are deliberately left alone: a row that has just been asked for
    /// is off the list but still approved, and stays approved until its bytes
    /// arrive - otherwise the next manifest would put it back through the gate.
    private func drop(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        state.update { snapshot in
            snapshot.pending.removeAll { keys.contains($0.key) }
            snapshot.notifiedKeys.removeAll { keys.contains($0) }
            if snapshot.pending.isEmpty { snapshot.pendingReason = nil }
        }
    }

    /// Takes rows off the list *and* withdraws any approval they had, which is
    /// what ignoring means: a key approved a moment ago and ignored now must not
    /// still be asked for on the next cycle.
    private func forget(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        state.update { snapshot in
            snapshot.pending.removeAll { keys.contains($0.key) }
            snapshot.approvedKeys.removeAll { keys.contains($0) }
            snapshot.notifiedKeys.removeAll { keys.contains($0) }
            if snapshot.pending.isEmpty { snapshot.pendingReason = nil }
        }
    }

    /// Tells whoever is listening about rows nobody has seen yet, once.
    private func announce(_ rows: [PhotoPendingAction]) {
        let known = Set(state.current.notifiedKeys)
        let fresh = rows.filter { !known.contains($0.key) }
        guard !fresh.isEmpty else { return }
        state.update { $0.notifiedKeys = rows.map(\.key) }
        let payload = fresh
        DispatchQueue.main.async { [weak self] in self?.onDecisionsNeeded?(payload) }
    }

    /// Asks for as much as one cycle may carry, newest first. Returns how many
    /// were actually asked for: zero means the phone could not be reached and
    /// nothing may be crossed off.
    @discardableResult
    private func fetch(_ want: [PhotoItem]) -> Int {
        guard !want.isEmpty else { return 0 }
        var batch: [String] = []
        var bytes: Int64 = 0
        for item in want.sorted(by: { $0.captureAt > $1.captureAt }) {
            if batch.count >= limits.itemsPerCycle { break }
            if !batch.isEmpty, bytes + item.size > limits.bytesPerCycle { break }
            batch.append(item.key)
            bytes += item.size
        }
        Log.info("Asking the phone for \(batch.count) photo(s), "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        guard request(batch, nil) else {
            // The phone is not there. Nothing is crossed off, so the click the
            // operator just made is not quietly lost.
            Log.error("The phone could not be asked for \(batch.count) photo(s); they stay on the list")
            return 0
        }
        return batch.count
    }

    // MARK: - The report

    public var report: PhotoSyncReport {
        let snapshot = state.current
        var report = PhotoSyncReport()
        report.imported = importer.importedCount
        report.pendingDecisions = snapshot.pending.count
        report.pendingReason = snapshot.pendingReason
        report.awaitingApproval = snapshot.awaitingTransfer.count
        report.awaitingBytes = snapshot.awaitingBytes
        report.pendingDeletions = importer.pendingDeletionCount
        report.removedByUser = importer.removedByUserCount
        report.ignored = importer.ignoredCount
        report.skipped = snapshot.skipped
        report.lastCycleAt = snapshot.lastCycleAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        report.windowFrom = snapshot.windowFrom.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        report.refusal = refusal
        return report
    }

    private func publish() {
        let report = self.report
        let pending = state.current.pending
        DispatchQueue.main.async { [weak self] in
            self?.onReport?(report)
            self?.onPendingChanged?(pending)
        }
    }
}
