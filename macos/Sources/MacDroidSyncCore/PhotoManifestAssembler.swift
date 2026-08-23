import Foundation

/// Collects the pages of one manifest and decides whether what arrived can be
/// trusted enough to delete anything.
///
/// This is the completeness gate, and it exists because absence is the signal
/// the delete rule reads. A manifest that lost its last page looks exactly like
/// a manifest saying "those photos are gone". So a snapshot is only `complete`
/// when every page of one `manifestId` arrived and the item count matches the
/// number the phone promised; anything else stays `incomplete` and may be used
/// to fetch, never to delete.
///
/// State lives in memory on purpose: a half-collected snapshot must not survive
/// a disconnect and be compared later, when it no longer describes the phone.
public final class PhotoManifestAssembler {

    public struct Snapshot: Equatable {
        public let manifestId: String
        /// The window bound the phone applied. The delete rule uses this and
        /// never a bound computed on this side.
        public let from: Int64
        public let items: [PhotoItem]
        public let tombstones: [String]
        /// Items the phone could not place, for the report.
        public let skipped: Int
    }

    public enum Outcome: Equatable {
        /// Still waiting for pages. Fetching what is already known is safe.
        case incomplete(received: Int, of: Int)
        /// Every page arrived and the counts agree.
        case complete(Snapshot)
        /// A page-zero correction: keys the phone says are gone. Applies on its
        /// own, without inferring anything from absence.
        case correction([String])
        /// The phone said it cannot produce a trustworthy picture, or the pages
        /// contradict each other. Nothing at all happens.
        case rejected(String)
    }

    private var manifestId: String?
    private var pages: Int = 0
    private var expected: Int = 0
    private var from: Int64 = 0
    private var received: [Int: [PhotoItem]] = [:]
    private var tombstones: [String] = []
    private var skipped: Int = 0

    public init() {}

    /// Feeds one `photo-manifest` message in. `ok` is the message's own flag:
    /// false means the phone is refusing to describe the library, which is the
    /// guard against a narrowed media permission looking like a mass deletion.
    public func accept(_ payload: PhotoPayload, ok: Bool = true, reason: String? = nil) -> Outcome {
        guard ok else {
            reset()
            return .rejected(reason ?? "the phone would not describe its camera folder")
        }
        // A correction carries only tombstones and is never part of a snapshot.
        if payload.page == 0 {
            let gone = payload.gone ?? []
            return .correction(gone)
        }
        guard let id = payload.manifestId,
              let page = payload.page,
              let pages = payload.pages,
              let count = payload.count,
              let from = payload.from,
              page >= 1, pages >= 1, page <= pages, count >= 0
        else {
            reset()
            return .rejected("a manifest page arrived without its page numbering")
        }
        // A different snapshot supersedes whatever was half-collected: two
        // overlapping cycles must never be merged into one picture.
        if id != manifestId {
            reset()
            manifestId = id
            self.pages = pages
            self.expected = count
            self.from = from
        }
        guard pages == self.pages, count == self.expected, from == self.from else {
            let stale = manifestId ?? id
            reset()
            return .rejected("the pages of manifest \(stale) disagree about its size")
        }

        received[page] = payload.items ?? []
        tombstones.append(contentsOf: payload.gone ?? [])
        skipped = max(skipped, payload.skipped ?? 0)

        let total = received.values.reduce(0) { $0 + $1.count }
        guard received.count == pages else {
            return .incomplete(received: total, of: expected)
        }
        guard total == expected else {
            // Every page arrived and the arithmetic still does not work out. Not
            // worth guessing which side is wrong; refuse the whole snapshot.
            let stale = manifestId ?? id
            reset()
            return .rejected("manifest \(stale) promised \(expected) items and delivered \(total)")
        }

        let items = received.keys.sorted().flatMap { received[$0] ?? [] }
        let snapshot = Snapshot(manifestId: id, from: from, items: items,
                                tombstones: tombstones, skipped: skipped)
        reset()
        return .complete(snapshot)
    }

    /// Drops a half-collected snapshot: on disconnect, or when a cycle is
    /// abandoned. Called by the session, and by this type whenever it refuses.
    public func reset() {
        manifestId = nil
        pages = 0
        expected = 0
        from = 0
        received.removeAll()
        tombstones.removeAll()
        skipped = 0
    }
}
