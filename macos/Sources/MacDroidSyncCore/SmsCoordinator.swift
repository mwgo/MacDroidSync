import Foundation

/// Keeps `SmsStore` in step with the phone and matches answers to requests.
///
/// Main queue only. Knows nothing about windows: whoever shows messages reads
/// the store and listens to `onChange`.
public final class SmsCoordinator {

    public enum Event {
        /// The list, or the messages of this conversation, changed.
        case threads
        case messages(Int64)
        /// A request could not be answered: the phone's reason, or a timeout.
        case failed(String)
        case image(partId: String, data: Data?, reason: String?)
    }

    private enum Request {
        case threads
        case thread(Int64, before: Int64?)
        case image(String)
        case send(localId: String)
    }

    public let store: SmsStore
    private let transport: (String, SmsPayload) -> Bool
    private let timeout: TimeInterval

    public var onEvent: ((Event) -> Void)?
    /// Messages that arrived while the phone was connected, for a notification.
    public var onIncoming: ((SmsThread, [SmsMessage]) -> Void)?

    /// Why the phone will not share its messages, as it said; nil when it does.
    public private(set) var refusal: String?
    public private(set) var lastSync: Date?

    /// When each conversation was last looked at here, so its unread mark can
    /// go even though this Mac cannot mark anything read on the phone.
    private var seen: [Int64: Int64] = [:]

    private var pending: [String: Request] = [:]
    /// Messages typed here and not yet seen in a page from the phone, per
    /// conversation. Kept in memory only: the phone's own record replaces them.
    private var outgoing: [Int64: [SmsMessage]] = [:]

    public init(store: SmsStore, timeout: TimeInterval = 10, transport: @escaping (String, SmsPayload) -> Bool) {
        self.store = store
        self.timeout = timeout
        self.transport = transport
    }

    // MARK: - Asking

    @discardableResult
    public func refreshThreads() -> Bool {
        if pending.values.contains(where: { if case .threads = $0 { return true } else { return false } }) {
            return true
        }
        return ask(MessageType.smsThreads, SmsPayload(), .threads)
    }

    /// The newest page of one conversation, or the page older than what is
    /// stored when `older` is set.
    @discardableResult
    public func load(threadId: Int64, older: Bool = false) -> Bool {
        let before = older ? store.messages(in: threadId).first?.date : nil
        if older && before == nil { return false }
        return ask(
            MessageType.smsThread,
            SmsPayload(threadId: threadId, before: before, limit: SmsRules.pageSize),
            .thread(threadId, before: before)
        )
    }

    @discardableResult
    public func requestImage(partId: String) -> Bool {
        if let data = store.image(partId: partId) {
            onEvent?(.image(partId: partId, data: data, reason: nil))
            return true
        }
        return ask(MessageType.smsImage, SmsPayload(partId: partId), .image(partId))
    }

    /// Sends `text` into a conversation. The message shows at once as
    /// "Sending…"; false when there is no phone to send it.
    @discardableResult
    public func send(_ text: String, to thread: SmsThread, now: Date = Date()) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, thread.canReply, let address = thread.addresses.first else { return false }
        let localId = "local-\(UUID().uuidString)"
        let payload = SmsPayload(threadId: thread.id, address: address, text: body)
        guard ask(MessageType.smsSend, payload, .send(localId: localId), expires: false) else { return false }
        let message = SmsMessage(
            id: localId,
            date: Int64(now.timeIntervalSince1970 * 1000),
            fromMe: true,
            text: body,
            status: "pending"
        )
        outgoing[thread.id, default: []].append(message)
        onEvent?(.messages(thread.id))
        return true
    }

    /// What the window shows: the stored messages plus those still on their way.
    public func messages(in threadId: Int64) -> [SmsMessage] {
        let stored = store.messages(in: threadId)
        let local = outgoing[threadId] ?? []
        return (stored + local).sorted { $0.date < $1.date }
    }

    public func markSeen(_ threadId: Int64) {
        guard let thread = store.thread(threadId) else { return }
        seen[threadId] = thread.date
    }

    public func isUnread(_ thread: SmsThread) -> Bool {
        thread.unread > 0 && thread.date > (seen[thread.id] ?? Int64.min)
    }

    public var unreadCount: Int {
        store.threads.filter(isUnread).count
    }

    // MARK: - Session

    public func connected() {
        refreshThreads()
    }

    /// Requests in flight will not be answered by a phone that is gone.
    public func disconnected() {
        for (id, request) in pending {
            if case .send(let localId) = request { markOutgoing(localId, status: "failed", onlyIfPending: true) }
            pending[id] = nil
        }
    }

    // MARK: - Answers

    public func handle(_ reply: SmsReply) {
        switch reply.type {
        case MessageType.smsNew:
            guard let thread = reply.payload.thread else { return }
            let messages = reply.payload.messages ?? []
            store.appendIncoming(thread: thread, messages: messages)
            onEvent?(.threads)
            onEvent?(.messages(thread.id))
            if !messages.isEmpty { onIncoming?(thread, messages) }
            return
        case MessageType.smsChanged:
            refreshThreads()
            return
        default:
            break
        }

        guard let id = reply.payload.requestId, let request = pending[id] else { return }
        if reply.type != MessageType.smsStatus || reply.payload.state != "sent" {
            pending[id] = nil
        }
        switch request {
        case .threads:
            guard reply.ok else {
                refusal = reply.reason ?? "the phone did not share its messages"
                onEvent?(.failed(refusal!))
                onEvent?(.threads)
                return
            }
            refusal = nil
            lastSync = Date()
            store.replaceThreads(reply.payload.threads ?? [])
            onEvent?(.threads)
        case .thread(let threadId, let before):
            guard reply.ok else {
                onEvent?(.failed(reply.reason ?? "the phone did not send the conversation"))
                return
            }
            let messages = reply.payload.messages ?? []
            store.applyPage(threadId: threadId, messages: messages, more: reply.payload.more ?? false, before: before)
            settleOutgoing(threadId, against: messages)
            onEvent?(.messages(threadId))
        case .image(let partId):
            if reply.ok, let data = reply.image {
                store.storeImage(data, partId: partId)
                onEvent?(.image(partId: partId, data: data, reason: nil))
            } else {
                onEvent?(.image(partId: partId, data: nil, reason: reply.reason ?? "the phone has no such picture"))
            }
        case .send(let localId):
            let state = reply.ok ? (reply.payload.state ?? "sent") : "failed"
            markOutgoing(localId, status: state)
            if state == "failed", let reason = reply.reason {
                onEvent?(.failed(reason))
            }
            if state != "failed", let threadId = reply.payload.threadId {
                load(threadId: threadId)
            }
        }
    }

    // MARK: - Bookkeeping

    private func ask(_ type: String, _ payload: SmsPayload, _ request: Request, expires: Bool = true) -> Bool {
        let id = UUID().uuidString
        var payload = payload
        payload.requestId = id
        pending[id] = request
        guard transport(type, payload) else {
            pending[id] = nil
            return false
        }
        if expires {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire(id)
            }
        }
        return true
    }

    private func expire(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        if case .image(let partId) = request {
            onEvent?(.image(partId: partId, data: nil, reason: "the phone did not answer"))
        } else {
            onEvent?(.failed("the phone did not answer"))
        }
    }

    private func markOutgoing(_ localId: String, status: String, onlyIfPending: Bool = false) {
        for (threadId, list) in outgoing {
            guard let index = list.firstIndex(where: { $0.id == localId }) else { continue }
            if onlyIfPending && list[index].status != "pending" { continue }
            outgoing[threadId]![index].status = status
            onEvent?(.messages(threadId))
        }
    }

    /// A message typed here is dropped once the phone's page holds it: same text,
    /// sent by this side, no earlier than a minute before it was typed.
    private func settleOutgoing(_ threadId: Int64, against page: [SmsMessage]) {
        guard var list = outgoing[threadId] else { return }
        var available = page.filter(\.fromMe)
        list.removeAll { local in
            guard local.status != "failed",
                  let index = available.firstIndex(where: { $0.text == local.text && $0.date >= local.date - 60_000 })
            else { return false }
            available.remove(at: index)
            return true
        }
        outgoing[threadId] = list.isEmpty ? nil : list
    }
}
