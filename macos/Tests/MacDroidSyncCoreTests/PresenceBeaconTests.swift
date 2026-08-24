import XCTest
@testable import MacDroidSyncCore

/// Identity of the presence beacon. The vectors here are the same ones the
/// Kotlin suite asserts (see PROTOCOL.md section 6), which is what keeps the
/// phone's advertisement recognisable to this Mac.
final class PresenceBeaconTests: XCTestCase {
    private let code = "ABCD-EFGH-JKLM-NPQR"
    /// 1700000000 / 30, the same instant the channel vectors use.
    private let slot: Int64 = 56_666_666
    private let flags = PresenceBeacon.flagAutoLock

    func testServiceUUIDMatchesTheCrossPlatformVector() {
        XCTAssertEqual(
            PresenceBeacon.serviceUUIDBytes(pairingCode: code).map { String(format: "%02x", $0) }.joined(),
            "993bbecdd85ea9a50f0f705378a22fac"
        )
        XCTAssertEqual(
            PresenceBeacon.serviceUUID(pairingCode: code).uuidString,
            "993BBECD-D85E-A9A5-0F0F-705378A22FAC"
        )
    }

    func testTheUUIDIsDifferentFromTheChannelKey() {
        // Same pairing code, different HKDF info: broadcasting the beacon must
        // not leak anything about the key that encrypts the clipboard.
        let channelKey = CryptoBox.deriveKey(pairingCode: code).withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(channelKey.prefix(16), PresenceBeacon.serviceUUIDBytes(pairingCode: code))
    }

    func testADifferentPairingCodeIsADifferentBeacon() {
        XCTAssertNotEqual(
            PresenceBeacon.serviceUUIDBytes(pairingCode: code),
            PresenceBeacon.serviceUUIDBytes(pairingCode: "ABCD-EFGH-JKLM-NPQS")
        )
    }

    func testPayloadMatchesTheCrossPlatformVector() {
        let payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot)
        XCTAssertEqual(payload.count, PresenceBeacon.payloadLength)
        XCTAssertEqual(payload.map { String(format: "%02x", $0) }.joined(), "01ae64c93d94")
    }

    func testTheCurrentAndTheNeighbouringSlotsAreAccepted() {
        // The clocks of the two devices are never exactly the same.
        for offset in [-1, 0, 1] {
            let payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot + Int64(offset))
            XCTAssertEqual(
                PresenceBeacon.verify(payload: payload, pairingCode: code, at: date(for: slot)),
                flags,
                "slot offset \(offset) has to be tolerated"
            )
        }
    }

    /// The window is not about clock skew, it is about Doze. A suspended phone
    /// gets no CPU, so it keeps broadcasting the token it published before it
    /// went under while the controller repeats the packet regardless; anything
    /// narrower than this reads a phone lying on the desk as a phone that left.
    func testAPayloadFrozenByASuspendedPhoneIsStillAccepted() {
        for offset in [-PresenceBeacon.slotTolerance, -20, 20, PresenceBeacon.slotTolerance] {
            let payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot + offset)
            XCTAssertEqual(
                PresenceBeacon.verify(payload: payload, pairingCode: code, at: date(for: slot)),
                flags,
                "slot offset \(offset) is inside the tolerance and has to be accepted"
            )
        }
    }

    func testASlotTooFarAwayIsRejected() {
        let beyond = PresenceBeacon.slotTolerance + 1
        for offset in [-2880, -beyond, beyond, 2880] {
            let payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot + offset)
            XCTAssertNil(
                PresenceBeacon.verify(payload: payload, pairingCode: code, at: date(for: slot)),
                "a recorded packet from slot offset \(offset) must not still work"
            )
        }
    }

    func testAnotherPairingCodeIsRejected() {
        let payload = PresenceBeacon.payload(pairingCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ", flags: flags, slot: slot)
        XCTAssertNil(PresenceBeacon.verify(payload: payload, pairingCode: code, at: date(for: slot)))
    }

    func testFlippingTheFlagsBreaksTheToken() {
        var payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot)
        payload[payload.startIndex] = 0x00
        XCTAssertNil(
            PresenceBeacon.verify(payload: payload, pairingCode: code, at: date(for: slot)),
            "the flags are covered by the HMAC"
        )
    }

    func testAMalformedPayloadIsRejected() {
        let good = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot)
        let at = date(for: slot)
        XCTAssertNil(PresenceBeacon.verify(payload: Data(), pairingCode: code, at: at))
        XCTAssertNil(PresenceBeacon.verify(payload: good.dropLast(), pairingCode: code, at: at))
        XCTAssertNil(PresenceBeacon.verify(payload: good + Data([0]), pairingCode: code, at: at))
    }

    func testManufacturerDataIsUnwrappedAndFiltered() {
        let payload = PresenceBeacon.payload(pairingCode: code, flags: flags, slot: slot)
        // Company id 0xFFFF, little endian, exactly as CoreBluetooth reports it.
        let advertised = Data([0xFF, 0xFF]) + payload
        XCTAssertEqual(PresenceBeacon.payload(fromManufacturerData: advertised), payload)

        // Somebody else's beacon, of which there are plenty in the air.
        XCTAssertNil(PresenceBeacon.payload(fromManufacturerData: Data([0x4C, 0x00]) + payload))
        XCTAssertNil(PresenceBeacon.payload(fromManufacturerData: Data([0xFF, 0xFF])))
        XCTAssertNil(PresenceBeacon.payload(fromManufacturerData: advertised.dropLast()))
        XCTAssertNil(PresenceBeacon.payload(fromManufacturerData: advertised + Data([0x00])))
    }

    func testTheWholeAdvertisementFitsInThirtyOneBytes() {
        // 3 flags + 18 service UUID + 2 header + 2 company id + payload.
        let advertisement = 3 + 18 + 2 + 2 + PresenceBeacon.payloadLength
        XCTAssertLessThanOrEqual(advertisement, 31, "a longer payload would not be broadcast at all")
    }

    func testSlotDerivation() {
        // The slot boundary lands on a multiple of 30, not on a round timestamp:
        // 56666666 * 30 is 1699999980, so this slot ends at 1700000010.
        XCTAssertEqual(PresenceBeacon.slot(at: Date(timeIntervalSince1970: 1_699_999_980)), slot)
        XCTAssertEqual(PresenceBeacon.slot(at: Date(timeIntervalSince1970: 1_700_000_000)), slot)
        XCTAssertEqual(PresenceBeacon.slot(at: Date(timeIntervalSince1970: 1_700_000_009)), slot)
        XCTAssertEqual(PresenceBeacon.slot(at: Date(timeIntervalSince1970: 1_700_000_010)), slot + 1)
    }

    private func date(for slot: Int64) -> Date {
        Date(timeIntervalSince1970: Double(slot * PresenceBeacon.slotSeconds))
    }
}
