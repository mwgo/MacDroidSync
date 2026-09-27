import Foundation

/// Messages, see PROTOCOL.md section 9: what travels, and the pure rules the
/// window lays a conversation out with.

public struct SmsThread: Codable, Equatable {
    public var id: Int64
    public var addresses: [String]
    /// The contact's name on the phone, when it may read contacts.
    public var name: String?
    public var snippet: String?
    /// Last activity, milliseconds since 1970.
    public var date: Int64
    public var unread: Int
    public var lastFromMe: Bool?
    public var count: Int?
    /// The contact photo's id on the phone; the picture comes with `sms-avatar`.
    /// A new id means a new photo.
    public var photo: String?

    public init(
        id: Int64,
        addresses: [String],
        name: String? = nil,
        snippet: String? = nil,
        date: Int64,
        unread: Int = 0,
        lastFromMe: Bool? = nil,
        count: Int? = nil,
        photo: String? = nil
    ) {
        self.id = id
        self.addresses = addresses
        self.name = name
        self.snippet = snippet
        self.date = date
        self.unread = unread
        self.lastFromMe = lastFromMe
        self.count = count
        self.photo = photo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        date = try c.decodeIfPresent(Int64.self, forKey: .date) ?? 0
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        lastFromMe = try c.decodeIfPresent(Bool.self, forKey: .lastFromMe)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        photo = try c.decodeIfPresent(String.self, forKey: .photo)
    }

    /// What the list and the notification call this conversation.
    public var title: String {
        if let name, !name.isEmpty { return name }
        return addresses.isEmpty ? "Unknown" : addresses.joined(separator: ", ")
    }

    /// A sender name like "BANK" cannot take a reply, and neither can a group.
    public var canReply: Bool {
        addresses.count == 1 && SmsRules.canReply(addresses[0])
    }
}

public struct SmsImage: Codable, Equatable {
    public var partId: String
    public var mime: String?
    public var width: Int?
    public var height: Int?

    public init(partId: String, mime: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.partId = partId
        self.mime = mime
        self.width = width
        self.height = height
    }
}

/// One message. `id` carries "s" or "m" in front, because the phone numbers its
/// SMS and MMS rows independently.
public struct SmsMessage: Codable, Equatable {
    public var id: String
    public var date: Int64
    public var fromMe: Bool
    public var text: String?
    public var mms: Bool?
    public var images: [SmsImage]?
    /// "pending", "sent", "delivered" or "failed"; absent for received ones.
    /// A plain string: a word this Mac does not know must not break decoding.
    public var status: String?
    /// The sender, in a group conversation.
    public var address: String?

    public init(
        id: String,
        date: Int64,
        fromMe: Bool,
        text: String? = nil,
        mms: Bool? = nil,
        images: [SmsImage]? = nil,
        status: String? = nil,
        address: String? = nil
    ) {
        self.id = id
        self.date = date
        self.fromMe = fromMe
        self.text = text
        self.mms = mms
        self.images = images
        self.status = status
        self.address = address
    }

    public var dateValue: Date { Date(timeIntervalSince1970: TimeInterval(date) / 1000) }
}

/// The `sms` field of a message. Which fields are set depends on the type, see
/// the table in PROTOCOL.md section 9.
public struct SmsPayload: Codable, Equatable {
    public var requestId: String?
    public var threadId: Int64?
    public var after: Int64?
    public var before: Int64?
    public var limit: Int?
    public var threads: [SmsThread]?
    public var messages: [SmsMessage]?
    public var more: Bool?
    public var thread: SmsThread?
    public var address: String?
    public var text: String?
    public var state: String?
    public var partId: String?
    /// On `sms-avatar`: the photo id asked about, echoed back.
    public var photo: String?

    public init(
        requestId: String? = nil,
        threadId: Int64? = nil,
        after: Int64? = nil,
        before: Int64? = nil,
        limit: Int? = nil,
        threads: [SmsThread]? = nil,
        messages: [SmsMessage]? = nil,
        more: Bool? = nil,
        thread: SmsThread? = nil,
        address: String? = nil,
        text: String? = nil,
        state: String? = nil,
        partId: String? = nil,
        photo: String? = nil
    ) {
        self.requestId = requestId
        self.threadId = threadId
        self.after = after
        self.before = before
        self.limit = limit
        self.threads = threads
        self.messages = messages
        self.more = more
        self.thread = thread
        self.address = address
        self.text = text
        self.state = state
        self.partId = partId
        self.photo = photo
    }
}

/// A picture on its way out, already a JPEG small enough to travel.
public struct SmsOutgoingImage {
    public var jpeg: Data
    public var width: Int
    public var height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }
}

/// One message about messages from the phone, as the session hands it on.
public struct SmsReply {
    public var type: String
    public var payload: SmsPayload
    public var ok: Bool
    public var reason: String?
    /// The JPEG of an `sms-image` answer.
    public var image: Data?

    public init(type: String, payload: SmsPayload, ok: Bool = true, reason: String? = nil, image: Data? = nil) {
        self.type = type
        self.payload = payload
        self.ok = ok
        self.reason = reason
        self.image = image
    }
}

public enum SmsRules {
    public static let pageSize = 100

    public static func canReply(_ address: String) -> Bool {
        address.filter(\.isNumber).count >= 3
    }

    /// Up to two letters for the round avatar; nil for a bare number.
    public static func initials(of thread: SmsThread) -> String? {
        guard let name = thread.name, !name.isEmpty else { return nil }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "," }).filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? nil : letters.joined()
    }
}

// MARK: - Layout of one conversation

/// One row of the conversation view.
public enum SmsRow: Equatable {
    /// "Today", "Yesterday", a weekday within the last week, else a date.
    case day(String)
    /// `showsMeta`: the last message of a run from the same side, which carries
    /// the time (and the delivery state of the last one sent).
    case message(SmsMessage, groupedWithPrevious: Bool, meta: String?)
}

public enum SmsLayout {

    public static func rows(
        for messages: [SmsMessage],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [SmsRow] {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short

        let lastSent = messages.lastIndex(where: { $0.fromMe })
        var rows: [SmsRow] = []
        var previous: SmsMessage?
        for (index, message) in messages.enumerated() {
            let date = message.dateValue
            let newDay = previous.map { !calendar.isDate($0.dateValue, inSameDayAs: date) } ?? true
            if newDay {
                rows.append(.day(dayLabel(for: date, now: now, calendar: calendar, locale: locale)))
            }
            let grouped = !newDay && previous?.fromMe == message.fromMe
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let endsRun = next.map { $0.fromMe != message.fromMe || !calendar.isDate($0.dateValue, inSameDayAs: date) } ?? true
            let state = message.fromMe ? stateLabel(message.status, isLastSent: index == lastSent) : nil
            var meta: String?
            if endsRun || state == "Not sent" || state == "Sending…" {
                meta = [time.string(from: date), state].compactMap { $0 }.joined(separator: " · ")
            }
            rows.append(.message(message, groupedWithPrevious: grouped, meta: meta))
            previous = message
        }
        return rows
    }

    /// Failures and messages still on their way are always labelled; a delivery
    /// only on the last message sent, as the phone's own app does.
    static func stateLabel(_ status: String?, isLastSent: Bool) -> String? {
        switch status {
        case "failed": return "Not sent"
        case "pending": return "Sending…"
        case "delivered": return isLastSent ? "Delivered" : nil
        case "sent": return isLastSent ? "Sent" : nil
        default: return nil
        }
    }

    public static func dayLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? 0
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if days > 1 && days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// The time next to a conversation in the list.
    public static func listTime(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        let label = dayLabel(for: date, now: now, calendar: calendar, locale: locale)
        if label == "Yesterday" { return label }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}
