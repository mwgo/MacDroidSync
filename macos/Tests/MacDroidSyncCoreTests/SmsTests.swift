import XCTest
@testable import MacDroidSyncCore

final class SmsPayloadTests: XCTestCase {

    /// The JSON the phone writes, key for key, see SmsTest.kt.
    func testThePhonesJsonDecodes() throws {
        let json = """
        {"v":1,"seq":3,"type":"sms-thread","ts":1,
         "sms":{"requestId":"r1","threadId":7,"more":true,
                "messages":[{"id":"m3","date":1000,"fromMe":false,"text":"hi","mms":true,
                             "images":[{"partId":"12","mime":"image/jpeg","width":640,"height":480}],
                             "address":"+48600100200","extra":"ignored"}],
                "threads":[{"id":7,"addresses":["+48600100200"],"date":1000,"photo":"55"}]}}
        """
        let message = try Message.decode(Data(json.utf8))
        let sms = try XCTUnwrap(message.sms)
        XCTAssertEqual(sms.requestId, "r1")
        XCTAssertEqual(sms.threadId, 7)
        XCTAssertEqual(sms.messages?.first?.images?.first, SmsImage(partId: "12", mime: "image/jpeg", width: 640, height: 480))
        XCTAssertEqual(sms.threads?.first?.unread, 0)
        XCTAssertEqual(sms.threads?.first?.title, "+48600100200")
        XCTAssertEqual(sms.threads?.first?.photo, "55")
    }

    func testAPayloadSurvivesTheWire() throws {
        let payload = SmsPayload(requestId: "x", threadId: 2, before: 99, limit: 100, address: "+481", text: "a", state: "sent")
        let decoded = try Message.decode(try Message(type: MessageType.smsSend, sms: payload).encoded())
        XCTAssertEqual(decoded.sms, payload)
    }

    func testRepliesNeedANumberAndOnePerson() {
        XCTAssertTrue(SmsThread(id: 1, addresses: ["+48 600 100 200"], date: 0).canReply)
        XCTAssertFalse(SmsThread(id: 1, addresses: ["BANK"], date: 0).canReply)
        XCTAssertFalse(SmsThread(id: 1, addresses: ["+48600100200", "+48600100201"], date: 0).canReply)
    }

    func testInitials() {
        XCTAssertEqual(SmsRules.initials(of: SmsThread(id: 1, addresses: [], name: "Anna Kowalska", date: 0)), "AK")
        XCTAssertEqual(SmsRules.initials(of: SmsThread(id: 1, addresses: [], name: "Mama", date: 0)), "M")
        XCTAssertNil(SmsRules.initials(of: SmsThread(id: 1, addresses: ["+48"], date: 0)))
    }
}

final class SmsLayoutTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private var now: Date { Date(timeIntervalSince1970: TimeInterval(at(27, 12)) / 1000) }

    func testStampsRunsTailsAndTheLastDelivery() {
        let messages = [
            SmsMessage(id: "s1", date: at(26, 19, 42), fromMe: false, text: "Hej"),
            SmsMessage(id: "s2", date: at(26, 19, 50), fromMe: true, text: "Tak", status: "delivered"),
            SmsMessage(id: "s3", date: at(27, 10, 14), fromMe: false, text: "A"),
            SmsMessage(id: "s4", date: at(27, 10, 15), fromMe: false, text: "B"),
            SmsMessage(id: "s5", date: at(27, 11, 40), fromMe: true, text: "C", status: "delivered"),
        ]
        let rows = SmsLayout.rows(for: messages, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows[0], .day("Yesterday 19:42"))
        guard case .message(_, false, true, let earlier) = rows[2] else { return XCTFail("\(rows[2])") }
        XCTAssertNil(earlier, "an earlier delivery is not labelled")
        XCTAssertEqual(rows[3], .day("Today 10:14"))
        guard case .message(_, false, false, nil) = rows[4] else { return XCTFail("\(rows[4])") }
        guard case .message(_, true, true, nil) = rows[5] else { return XCTFail("\(rows[5])") }
        XCTAssertEqual(rows[6], .day("Today 11:40"), "an hour of silence shows the time again")
        guard case .message(_, false, true, "Delivered") = rows[7] else { return XCTFail("\(rows[7])") }
    }

    func testAFailureIsAlwaysLabelled() {
        let messages = [
            SmsMessage(id: "a", date: at(27, 9), fromMe: true, text: "1", status: "failed"),
            SmsMessage(id: "b", date: at(27, 9, 1), fromMe: true, text: "2", status: "sent"),
        ]
        let rows = SmsLayout.rows(for: messages, now: now, calendar: calendar, locale: locale)
        guard case .message(_, _, false, let first) = rows[1], case .message(_, true, true, let second) = rows[2] else {
            return XCTFail()
        }
        XCTAssertEqual(first, "Not sent")
        XCTAssertEqual(second, "Sent")
    }

    func testAnOlderStampSaysAt() {
        let date = Date(timeIntervalSince1970: TimeInterval(at(2, 19)) / 1000)
        let stamp = SmsLayout.stamp(for: date, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(stamp.hasPrefix("2 Sep") && stamp.hasSuffix("at 19:00"), stamp)
    }

    func testDayLabels() {
        let day = { (d: Int) in Date(timeIntervalSince1970: TimeInterval(self.at(d, 8)) / 1000) }
        XCTAssertEqual(SmsLayout.dayLabel(for: day(25), now: now, calendar: calendar, locale: locale), "Friday")
        let older = SmsLayout.dayLabel(for: day(15), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(older.hasPrefix("15 Sep") && older.hasSuffix("2026"), older)
    }
}

final class SmsStoreTests: XCTestCase {

    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeStore(imageLimit: Int = 1_000_000) -> SmsStore {
        SmsStore(
            directory: folder.appendingPathComponent("Messages"),
            imageDirectory: folder.appendingPathComponent("Images"),
            imageLimit: imageLimit
        )
    }

    private func message(_ id: String, _ date: Int64) -> SmsMessage {
        SmsMessage(id: id, date: date, fromMe: false, text: id)
    }

    func testWhatIsStoredSurvivesARestart() {
        let store = makeStore()
        store.replaceThreads([SmsThread(id: 1, addresses: ["+481"], date: 5)])
        store.applyPage(threadId: 1, messages: [message("s1", 1), message("s2", 2)], more: false, before: nil)
        let again = makeStore()
        XCTAssertEqual(again.threads.map(\.id), [1])
        XCTAssertEqual(again.messages(in: 1).map(\.id), ["s1", "s2"])
        XCTAssertFalse(again.hasOlder(in: 1))
    }

    func testTheFilesArePrivate() throws {
        let store = makeStore()
        store.replaceThreads([SmsThread(id: 1, addresses: ["+481"], date: 5)])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("Messages/threads.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testANewestPageReplacesItsStretch() {
        let store = makeStore()
        store.applyPage(threadId: 1, messages: [message("s1", 1), message("s2", 2), message("s3", 3)], more: true, before: nil)
        // s3 was deleted on the phone, s4 arrived.
        store.applyPage(threadId: 1, messages: [message("s2", 2), message("s4", 4)], more: true, before: nil)
        XCTAssertEqual(store.messages(in: 1).map(\.id), ["s1", "s2", "s4"])
    }

    func testACompletePageIsTheWholeConversation() {
        let store = makeStore()
        store.applyPage(threadId: 1, messages: [message("s1", 1), message("s2", 2)], more: true, before: nil)
        store.applyPage(threadId: 1, messages: [message("s2", 2)], more: false, before: nil)
        XCTAssertEqual(store.messages(in: 1).map(\.id), ["s2"])
    }

    func testAnOlderPageGoesInFront() {
        let store = makeStore()
        store.applyPage(threadId: 1, messages: [message("s3", 3)], more: true, before: nil)
        store.applyPage(threadId: 1, messages: [message("s1", 1), message("s2", 2)], more: false, before: 3)
        XCTAssertEqual(store.messages(in: 1).map(\.id), ["s1", "s2", "s3"])
        XCTAssertFalse(store.hasOlder(in: 1))
    }

    func testAConversationGoneFromThePhoneGoesHereToo() {
        let store = makeStore()
        store.replaceThreads([SmsThread(id: 1, addresses: [], date: 1), SmsThread(id: 2, addresses: [], date: 2)])
        store.applyPage(threadId: 1, messages: [message("s1", 1)], more: false, before: nil)
        store.replaceThreads([SmsThread(id: 2, addresses: [], date: 2)])
        XCTAssertEqual(makeStore().messages(in: 1), [])
    }

    func testIncomingMessagesMoveTheirConversationUp() {
        let store = makeStore()
        store.replaceThreads([SmsThread(id: 1, addresses: [], date: 10), SmsThread(id: 2, addresses: [], date: 5)])
        store.appendIncoming(thread: SmsThread(id: 2, addresses: [], date: 20, unread: 1), messages: [message("s9", 20)])
        XCTAssertEqual(store.threads.map(\.id), [2, 1])
        XCTAssertEqual(store.messages(in: 2).map(\.id), ["s9"])
    }

    func testPicturesAreKeptAndTrimmed() {
        let store = makeStore(imageLimit: 250)
        store.storeImage(Data(count: 200), partId: "1")
        XCTAssertEqual(store.image(partId: "1")?.count, 200)
        Thread.sleep(forTimeInterval: 0.05)
        store.storeImage(Data(count: 200), partId: "2")
        XCTAssertNil(store.image(partId: "1"), "the oldest picture goes first")
        XCTAssertNotNil(store.image(partId: "2"))
    }

    func testContactPhotosAreKeptByTheirId() {
        let store = makeStore()
        store.storeAvatar(Data([7]), photo: "55")
        XCTAssertEqual(makeStore().avatar(photo: "55"), Data([7]))
        XCTAssertNil(store.avatar(photo: "56"), "a new photo id is a new photo")
        XCTAssertNil(store.image(partId: "55"), "photos and MMS pictures do not collide")
    }

    func testAPartIdNeverLeavesTheFolder() {
        let store = makeStore()
        store.storeImage(Data([1]), partId: "../../evil")
        XCTAssertNil(store.image(partId: "../../evil"))
    }

    func testRemoveAllForgetsEverything() {
        let store = makeStore()
        store.replaceThreads([SmsThread(id: 1, addresses: [], date: 1)])
        store.storeImage(Data([1]), partId: "3")
        store.removeAll()
        XCTAssertTrue(makeStore().threads.isEmpty)
        XCTAssertNil(makeStore().image(partId: "3"))
    }
}

final class SmsCoordinatorTests: XCTestCase {

    private var folder: URL!
    private var sent: [(String, SmsPayload)] = []
    private var sentImages: [Data?] = []
    private var connected = true

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sent = []
        connected = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCoordinator() -> SmsCoordinator {
        let store = SmsStore(directory: folder.appendingPathComponent("M"), imageDirectory: folder.appendingPathComponent("I"))
        return SmsCoordinator(store: store, timeout: 60) { [unowned self] type, payload, image in
            self.sentImages.append(image)
            guard self.connected else { return false }
            self.sent.append((type, payload))
            return true
        }
    }

    private let thread = SmsThread(id: 3, addresses: ["+48600100200"], name: "Anna", date: 100, unread: 1)

    func testAnAnswerIsMatchedToItsRequest() {
        let coordinator = makeCoordinator()
        coordinator.refreshThreads()
        let id = sent.last?.1.requestId
        coordinator.handle(SmsReply(type: MessageType.smsThreads, payload: SmsPayload(requestId: "someone else", threads: [thread])))
        XCTAssertTrue(coordinator.store.threads.isEmpty, "an answer to no request is dropped")
        coordinator.handle(SmsReply(type: MessageType.smsThreads, payload: SmsPayload(requestId: id, threads: [thread])))
        XCTAssertEqual(coordinator.store.threads, [thread])
        XCTAssertNotNil(coordinator.lastSync)
    }

    func testARefusalIsKept() {
        let coordinator = makeCoordinator()
        coordinator.refreshThreads()
        coordinator.handle(SmsReply(
            type: MessageType.smsThreads,
            payload: SmsPayload(requestId: sent.last?.1.requestId),
            ok: false,
            reason: "no permission"
        ))
        XCTAssertEqual(coordinator.refusal, "no permission")
    }

    func testNewMessagesAreStoredAndAnnounced() {
        let coordinator = makeCoordinator()
        var announced: [SmsMessage] = []
        coordinator.onIncoming = { _, messages in announced = messages }
        let message = SmsMessage(id: "s1", date: 100, fromMe: false, text: "Hej")
        coordinator.handle(SmsReply(type: MessageType.smsNew, payload: SmsPayload(messages: [message], thread: thread)))
        XCTAssertEqual(announced, [message])
        XCTAssertEqual(coordinator.store.messages(in: 3), [message])
        XCTAssertEqual(coordinator.unreadCount, 1)
        coordinator.markSeen(3)
        XCTAssertEqual(coordinator.unreadCount, 0)
    }

    func testWhatWasAnnouncedIsNotAnnouncedAgainAfterAReconnect() {
        let first = makeCoordinator()
        var announced: [[String]] = []
        first.onIncoming = { _, messages in announced.append(messages.map(\.id)) }
        let old = SmsMessage(id: "s1", date: 100, fromMe: false, text: "Hej")
        first.handle(SmsReply(type: MessageType.smsNew, payload: SmsPayload(messages: [old], thread: thread)))

        // A new session, a new process even: the phone repeats what is unread.
        let second = makeCoordinator()
        second.onIncoming = { _, messages in announced.append(messages.map(\.id)) }
        let newer = SmsMessage(id: "s2", date: 200, fromMe: false, text: "Jesteś?")
        second.handle(SmsReply(type: MessageType.smsNew, payload: SmsPayload(messages: [old, newer], thread: thread)))
        second.handle(SmsReply(type: MessageType.smsNew, payload: SmsPayload(messages: [old, newer], thread: thread)))
        XCTAssertEqual(announced, [["s1"], ["s2"]])
    }

    func testAConversationOpenedHereIsNotAnnouncedLater() {
        let coordinator = makeCoordinator()
        coordinator.store.replaceThreads([thread])
        coordinator.markSeen(3)
        var announced = false
        coordinator.onIncoming = { _, _ in announced = true }
        let message = SmsMessage(id: "s1", date: 100, fromMe: false, text: "Hej")
        coordinator.handle(SmsReply(type: MessageType.smsNew, payload: SmsPayload(messages: [message], thread: thread)))
        XCTAssertFalse(announced)
    }

    func testAChangeRefreshesTheList() {
        let coordinator = makeCoordinator()
        coordinator.handle(SmsReply(type: MessageType.smsChanged, payload: SmsPayload()))
        XCTAssertEqual(sent.last?.0, MessageType.smsThreads)
    }

    func testASentMessageShowsAtOnceAndMakesWayForThePhonesCopy() {
        let coordinator = makeCoordinator()
        coordinator.store.replaceThreads([thread])
        XCTAssertTrue(coordinator.send("  Hi  ", to: thread, now: Date(timeIntervalSince1970: 1)))
        let request = sent.last!
        XCTAssertEqual(request.0, MessageType.smsSend)
        XCTAssertEqual(request.1.text, "Hi")
        XCTAssertEqual(coordinator.messages(in: 3).map(\.status), ["pending"])

        coordinator.handle(SmsReply(
            type: MessageType.smsStatus,
            payload: SmsPayload(requestId: request.1.requestId, threadId: 3, state: "sent")
        ))
        XCTAssertEqual(coordinator.messages(in: 3).map(\.status), ["sent"])
        let reload = sent.last!
        XCTAssertEqual(reload.0, MessageType.smsThread)

        let recorded = SmsMessage(id: "s50", date: 1_200, fromMe: true, text: "Hi", status: "sent")
        coordinator.handle(SmsReply(
            type: MessageType.smsThread,
            payload: SmsPayload(requestId: reload.1.requestId, threadId: 3, messages: [recorded], more: false)
        ))
        XCTAssertEqual(coordinator.messages(in: 3), [recorded])
    }

    func testAPictureGoesOutAsAnMmsAndShowsAtOnce() {
        let coordinator = makeCoordinator()
        let jpeg = Data([0xFF, 0xD8, 1])
        XCTAssertTrue(coordinator.send("", image: SmsOutgoingImage(jpeg: jpeg, width: 40, height: 30), to: thread, now: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(sentImages.last, jpeg)
        XCTAssertNil(sent.last?.1.text)
        let local = coordinator.messages(in: 3)
        XCTAssertEqual(local.first?.mms, true)
        let partId = try! XCTUnwrap(local.first?.images?.first?.partId)
        XCTAssertEqual(coordinator.imageAtHand(partId: partId), jpeg)

        let reload = sent.last!
        coordinator.handle(SmsReply(type: MessageType.smsStatus, payload: SmsPayload(requestId: reload.1.requestId, threadId: 3, state: "sent")))
        let page = sent.last!
        let recorded = SmsMessage(id: "m9", date: 1_500, fromMe: true, mms: true, images: [SmsImage(partId: "44")], status: "sent")
        coordinator.handle(SmsReply(type: MessageType.smsThread, payload: SmsPayload(requestId: page.1.requestId, threadId: 3, messages: [recorded], more: false)))
        XCTAssertEqual(coordinator.messages(in: 3), [recorded])
        XCTAssertNil(coordinator.imageAtHand(partId: partId), "the local copy goes with its placeholder")
    }

    func testAFailedSendStaysVisible() {
        let coordinator = makeCoordinator()
        coordinator.send("Hi", to: thread)
        coordinator.handle(SmsReply(
            type: MessageType.smsStatus,
            payload: SmsPayload(requestId: sent.last?.1.requestId, state: "failed"),
            ok: false,
            reason: "no service"
        ))
        XCTAssertEqual(coordinator.messages(in: 3).map(\.status), ["failed"])
    }

    func testNothingIsSentWithoutAPhoneOrToASenderName() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.send("Hi", to: SmsThread(id: 1, addresses: ["BANK"], date: 0)))
        connected = false
        XCTAssertFalse(coordinator.send("Hi", to: thread))
        XCTAssertTrue(coordinator.messages(in: 3).isEmpty)
    }

    func testADisconnectFailsWhatWasStillSending() {
        let coordinator = makeCoordinator()
        coordinator.send("Hi", to: thread)
        coordinator.disconnected()
        XCTAssertEqual(coordinator.messages(in: 3).map(\.status), ["failed"])
    }

    func testAContactPhotoIsAskedForOnceAndStored() {
        let coordinator = makeCoordinator()
        let withPhoto = SmsThread(id: 3, addresses: ["+48600100200"], name: "Anna", date: 100, photo: "55")
        XCTAssertTrue(coordinator.requestAvatar(for: withPhoto))
        XCTAssertTrue(coordinator.requestAvatar(for: withPhoto))
        XCTAssertEqual(sent.filter { $0.0 == MessageType.smsAvatar }.count, 1, "one question while one is open")
        let request = sent.last!.1
        XCTAssertEqual(request.address, "+48600100200")
        XCTAssertEqual(request.photo, "55")
        var got: Data?
        coordinator.onEvent = { event in
            if case .avatar("55", let data) = event { got = data }
        }
        coordinator.handle(SmsReply(type: MessageType.smsAvatar, payload: request, image: Data([9])))
        XCTAssertEqual(got, Data([9]))
        XCTAssertEqual(coordinator.store.avatar(photo: "55"), Data([9]))
    }

    func testNoPhotoIsAskedForWithoutOne() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.requestAvatar(for: thread))
        XCTAssertTrue(sent.isEmpty)
    }

    func testAPictureAlreadyStoredIsNotAskedFor() {
        let coordinator = makeCoordinator()
        coordinator.store.storeImage(Data([1, 2]), partId: "8")
        var got: Data?
        coordinator.onEvent = { event in
            if case .image(_, let data, _) = event { got = data }
        }
        coordinator.requestImage(partId: "8")
        XCTAssertEqual(got, Data([1, 2]))
        XCTAssertTrue(sent.isEmpty)
    }
}
