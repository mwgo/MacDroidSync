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

/// What survives a restart between cycles: the plan waiting for the operator,
/// what the operator has already approved, and the last report.
public struct PhotoSyncState: Codable, Equatable {
    /// The plan nothing may move against until the operator says so.
    public var awaitingApproval: [PhotoItem] = []
    public var approvalReason: String?
    /// Exactly the keys the operator saw and approved - not a general licence.
    public var approvedKeys: [String] = []
    /// Whether the first-run report has been seen and accepted.
    ///
    /// This has to be remembered here rather than inferred from an empty index,
    /// and the reason is a loop: the gate's condition would be cleared by an
    /// import, and the gate is what stops the import. So the operator's click is
    /// the thing that opens it, once.
    public var approvedFirstRun: Bool = false
    public var skipped: [PhotoSkipped] = []
    public var lastCycleAt: Int64?
    public var windowFrom: Int64?

    public init() {}

    public var awaitingBytes: Int64 { awaitingApproval.reduce(0) { $0 + $1.size } }
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
    public var awaitingApproval: Int = 0
    public var awaitingBytes: Int64 = 0
    public var approvalReason: String?
    /// Waiting for the operator to press Remove. Nothing leaves the library
    /// before that.
    public var pendingDeletions: Int = 0
    public var removedByUser: Int = 0
    public var skipped: [PhotoSkipped] = []
    public var lastCycleAt: Date?
    public var windowFrom: Date?
    /// Set when the last thing the phone said was a refusal, so a feature that
    /// is doing nothing always says why.
    public var refusal: String?

    public init() {}
}

/// Drives one photo sync cycle: manifest in, plan out, and nothing at all until
/// the operator has approved anything large.
///
/// The gate is the point of this type. A plan is either small enough to be
/// ordinary work, or it stops here - and while it is stopped, not one offer goes
/// on the wire.
public final class PhotoSyncCoordinator {

    private let importer: PhotoImporter
    private let assembler: PhotoManifestAssembler
    private let state: PhotoSyncStateStore
    private let limits: PhotoSyncLimits
    private let request: ([String]?, String?) -> Void
    private let queue = DispatchQueue(label: "\(Log.subsystem).photo-coordinator")
    private var refusal: String?

    /// Fires whenever anything the UI shows has changed.
    public var onReport: ((PhotoSyncReport) -> Void)?

    public init(
        importer: PhotoImporter,
        state: PhotoSyncStateStore = PhotoSyncStateStore(),
        assembler: PhotoManifestAssembler = PhotoManifestAssembler(),
        limits: PhotoSyncLimits = PhotoSyncLimits(),
        request: @escaping ([String]?, String?) -> Void
    ) {
        self.importer = importer
        self.state = state
        self.assembler = assembler
        self.limits = limits
        self.request = request
    }

    // MARK: - What the operator does

    /// "Sync photos now": asks for a fresh manifest, whatever the interval says.
    public func syncNow() {
        refusal = nil
        request(nil, nil)
    }

    /// The operator approved the parked plan. Only the keys they were shown are
    /// approved; anything that turns up later goes through the gate again.
    public func approveWaitingPlan() {
        queue.sync {
            let waiting = state.current.awaitingApproval
            guard !waiting.isEmpty else { return }
            state.update { snapshot in
                snapshot.approvedKeys = waiting.map(\.key)
                snapshot.awaitingApproval = []
                snapshot.approvalReason = nil
                snapshot.approvedFirstRun = true
            }
            Log.info("Approved \(waiting.count) photo(s) for import")
        }
        // Ask for the first paced batch straight away rather than waiting for the
        // phone's next cycle: the operator just clicked, and nothing should look
        // like it was ignored.
        request(nil, nil)
        publish()
    }

    /// Forgets a parked plan without importing it.
    public func discardWaitingPlan() {
        state.update { snapshot in
            snapshot.awaitingApproval = []
            snapshot.approvalReason = nil
        }
        publish()
    }

    /// Removes what is waiting, in one batch, so the confirmation alert appears
    /// once rather than once per photo. The only way anything leaves the library.
    @discardableResult
    public func removeWaitingPhotos() -> PhotoDeletionOutcome {
        let outcome = importer.flushDeletions()
        publish()
        return outcome
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
        let plan = PhotoDelta.plan(
            items: snapshot.items,
            from: snapshot.from,
            tombstones: snapshot.tombstones,
            index: importer.indexedKeys,
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
        // for it, because macOS puts a confirmation alert in front of it - a
        // dialog appearing by itself, up to twice an hour, is not acceptable.
        if !plan.delete.isEmpty {
            importer.markGone(plan.delete.map(\.key))
        }
        if !plan.refusedDelete.isEmpty {
            // Marked like the rest - nothing happens without the click anyway -
            // but said out loud, because a batch this size is more likely a fault
            // than real tidying up, and the number in the menu is what the
            // operator will be judging.
            importer.markGone(plan.refusedDelete.map(\.key))
            Log.error("\(plan.refusedDelete.count) photos look deleted on the phone, which is more "
                + "than this Mac would expect. Check the count before removing them.")
        }

        state.update { snapshot2 in
            snapshot2.lastCycleAt = Message.now()
            snapshot2.windowFrom = snapshot.from
            snapshot2.skipped = plan.excluded.map {
                PhotoSkipped(name: ($0.key as NSString).lastPathComponent,
                             size: $0.size,
                             reason: $0.excluded ?? .unreadable)
            }
        }

        // What the operator already approved is past the gate; whatever turned up
        // afterwards has to face it on its own. Without that split, an approved
        // backlog of five thousand photos would be parked again by its own size.
        let approved = Set(stored.approvedKeys)
        let approvedWant = plan.want.filter { approved.contains($0.key) }
        let freshWant = plan.want.filter { !approved.contains($0.key) }

        let gate = PhotoDelta.approvalReason(for: freshWant, limits: limits, isFirstRun: isFirstRun)
        if let gate {
            park(freshWant, reason: gate)
        } else {
            state.update { snapshot in
                snapshot.awaitingApproval = []
                snapshot.approvalReason = nil
            }
        }
        // Approved work still moves while something new waits for a decision.
        fetch(approvedWant + (gate == nil ? freshWant : []), approved: approved)
        publish()
    }

    /// Stops the cycle and waits. Nothing goes on the wire for these items while
    /// they are here.
    private func park(_ want: [PhotoItem], reason: String) {
        state.update { snapshot in
            snapshot.awaitingApproval = want
            snapshot.approvalReason = reason
        }
        let bytes = want.reduce(Int64(0)) { $0 + $1.size }
        Log.info("Photo sync is waiting for you: \(want.count) item(s), "
            + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) - \(reason)")
    }

    /// Asks for as much as one cycle may carry, newest first.
    private func fetch(_ want: [PhotoItem], approved: Set<String>) {
        guard !want.isEmpty else { return }
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
        request(batch, nil)

        // Keys drop off the approved list once they have been asked for, so an
        // approved backlog drains rather than being asked for over and over.
        if !approved.isEmpty {
            let asked = Set(batch)
            state.update { snapshot in
                snapshot.approvedKeys = snapshot.approvedKeys.filter { !asked.contains($0) }
            }
        }
    }

    // MARK: - The report

    public var report: PhotoSyncReport {
        let snapshot = state.current
        var report = PhotoSyncReport()
        report.imported = importer.importedCount
        report.awaitingApproval = snapshot.awaitingApproval.count
        report.awaitingBytes = snapshot.awaitingBytes
        report.approvalReason = snapshot.approvalReason
        report.pendingDeletions = importer.pendingDeletionCount
        report.removedByUser = importer.removedByUserCount
        report.skipped = snapshot.skipped
        report.lastCycleAt = snapshot.lastCycleAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        report.windowFrom = snapshot.windowFrom.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        report.refusal = refusal
        return report
    }

    private func publish() {
        let report = self.report
        DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
    }
}
