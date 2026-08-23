import CryptoKit
import XCTest
@testable import MacDroidSyncCore

/// The vectors below are documented in PROTOCOL.md and asserted by the Kotlin
/// test suite as well, so both implementations stay byte compatible.
final class CryptoBoxTests: XCTestCase {
    private let pairingCode = "ABCD-EFGH-JKLM-NPQR"
    private let expectedKey = "8fbe4a33389056e7d5beebae8fa395bbb3f550ba601a2fa58742825b6729349e"
    private let nonceHex = "0a0b0c0d0000000000000001"
    private let plaintext = #"{"seq":1,"ts":1700000000000,"type":"ping","v":1}"#
    private let expectedSealed = """
        0a0b0c0d000000000000000153ee74cf645d5e54bcd32aa4545e08dd3481b931abaaf961\
        0008bdd6e02f3ac813e9ab23b25e59c926edff17cc448bc02664ab0c4cacf5f707397bd2\
        ac6c1e3c
        """

    func testNormalizationIgnoresCaseAndSeparators() {
        XCTAssertEqual(CryptoBox.normalize(pairingCode: "abcd efgh-jklm_npqr"), "ABCDEFGHJKLMNPQR")
    }

    func testDerivedKeyMatchesVector() {
        let key = CryptoBox.deriveKey(pairingCode: pairingCode)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.hexString, expectedKey)
        XCTAssertEqual(
            CryptoBox.deriveKey(pairingCode: "abcdefghjklmnpqr").withUnsafeBytes { Data($0) }.hexString,
            expectedKey
        )
    }

    func testSealMatchesVector() throws {
        let key = CryptoBox.deriveKey(pairingCode: pairingCode)
        let sealed = try CryptoBox.seal(
            plaintext: Data(plaintext.utf8),
            key: key,
            nonce: Data(hex: nonceHex)!
        )
        XCTAssertEqual(sealed.hexString, expectedSealed)
    }

    func testOpenVector() throws {
        let key = CryptoBox.deriveKey(pairingCode: pairingCode)
        let opened = try CryptoBox.open(body: Data(hex: expectedSealed)!, key: key)
        XCTAssertEqual(String(data: opened, encoding: .utf8), plaintext)

        let message = try Message.decode(opened)
        XCTAssertEqual(message.type, MessageType.ping)
        XCTAssertEqual(message.seq, 1)
        XCTAssertEqual(message.ts, 1_700_000_000_000)
    }

    func testWrongPairingCodeFailsAuthentication() {
        let key = CryptoBox.deriveKey(pairingCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        XCTAssertThrowsError(try CryptoBox.open(body: Data(hex: expectedSealed)!, key: key)) { error in
            XCTAssertEqual(error as? ProtocolError, ProtocolError.authenticationFailed)
        }
    }

    func testGeneratedPairingCodeShape() {
        let code = CryptoBox.generatePairingCode()
        XCTAssertEqual(code.count, 19)
        XCTAssertEqual(code.filter { $0 == "-" }.count, 3)
        XCTAssertEqual(CryptoBox.normalize(pairingCode: code).count, 16)
        XCTAssertNotEqual(code, CryptoBox.generatePairingCode())
    }

    func testCodecRoundTripAndNonceProgression() throws {
        let sender = FrameCodec(pairingCode: pairingCode)
        let receiver = FrameCodec(pairingCode: pairingCode)

        var bodies: [Data] = []
        for _ in 0 ..< 3 {
            let message = Message(seq: sender.nextSequence(), type: MessageType.heartbeat)
            bodies.append(try sender.seal(try message.encoded()))
        }
        let nonces = bodies.map { $0.prefix(12).hexString }
        XCTAssertEqual(Set(nonces).count, 3, "every frame must use a fresh nonce")
        XCTAssertEqual(Set(nonces.map { $0.prefix(8) }).count, 1, "nonce prefix is per session")

        for (index, body) in bodies.enumerated() {
            let message = try receiver.open(body)
            XCTAssertEqual(message.seq, UInt64(index + 1))
        }
    }

    func testReplayIsRejected() throws {
        let sender = FrameCodec(pairingCode: pairingCode)
        let receiver = FrameCodec(pairingCode: pairingCode)
        let body = try sender.seal(try Message(seq: sender.nextSequence(), type: MessageType.ping).encoded())

        XCTAssertNoThrow(try receiver.open(body))
        XCTAssertThrowsError(try receiver.open(body)) { error in
            XCTAssertEqual(error as? ProtocolError, ProtocolError.replayDetected(1))
        }
    }
}

final class FramingTests: XCTestCase {
    func testFrameMatchesVector() {
        let body = Data(hex: """
            0a0b0c0d000000000000000153ee74cf645d5e54bcd32aa4545e08dd3481b931abaaf961\
            0008bdd6e02f3ac813e9ab23b25e59c926edff17cc448bc02664ab0c4cacf5f707397bd2\
            ac6c1e3c
            """)!
        let frame = Framing.frame(kind: .encrypted, body: body)
        XCTAssertEqual(frame.count, 81)
        XCTAssertEqual(frame.prefix(5).hexString, "0000004d02")
    }

    func testPartialFrameIsBuffered() throws {
        let body = Data("hello".utf8)
        let frame = Framing.frame(kind: .plaintext, body: body)

        var buffer = frame.prefix(3)
        XCTAssertNil(try Framing.nextFrame(from: &buffer))
        buffer.append(frame.dropFirst(3).prefix(2))
        XCTAssertNil(try Framing.nextFrame(from: &buffer))

        buffer.append(frame.dropFirst(5))
        let parsed = try Framing.nextFrame(from: &buffer)
        XCTAssertEqual(parsed?.kind, .plaintext)
        XCTAssertEqual(parsed?.body, body)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTwoFramesInOneChunk() throws {
        var buffer = Framing.frame(kind: .plaintext, body: Data("one".utf8))
        buffer.append(Framing.frame(kind: .encrypted, body: Data("two".utf8)))

        XCTAssertEqual(try Framing.nextFrame(from: &buffer)?.body, Data("one".utf8))
        let second = try Framing.nextFrame(from: &buffer)
        XCTAssertEqual(second?.kind, .encrypted)
        XCTAssertEqual(second?.body, Data("two".utf8))
        XCTAssertNil(try Framing.nextFrame(from: &buffer))
    }

    func testOversizedLengthIsRejected() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try Framing.nextFrame(from: &buffer))
    }
}

extension ProtocolError: Equatable {
    public static func == (lhs: ProtocolError, rhs: ProtocolError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let cleaned = hex.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
