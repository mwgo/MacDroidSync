import CryptoKit
import Foundation

/// Identity of the Bluetooth LE presence beacon the phone broadcasts and this
/// Mac listens for, see PROTOCOL.md section 7.
///
/// Two things have to be true for the beacon to be usable at all:
///
///  * the Mac must recognise **its own** phone. Android rotates the advertising
///    MAC address, so the address is not an identifier; instead the 128 bit
///    service UUID is derived from the pairing code, which both sides already
///    share.
///  * a recorded packet must not stay valid forever. Replaying one would keep
///    the Mac unlocked, so the payload carries a truncated HMAC over the current
///    30 second slot; the Mac accepts one slot either side to tolerate clock
///    skew.
///
/// Everything travels in the primary advertisement, never in a scan response:
/// macOS merges a scan response into `advertisementData` only when it happens to
/// have one, so a token kept there would be missing from part of the callbacks.
/// That caps the payload, which is why the HMAC is truncated to five bytes:
///
///     flags element                       3 bytes
///     complete 128 bit service UUID      18 bytes
///     manufacturer data 0xFFFF + payload  4 + 6 bytes
///     ----------------------------------------------
///                                        31 bytes, the legacy limit
public enum PresenceBeacon {
    /// Bit 0 of the flags byte: the phone agrees to the Mac locking itself.
    public static let flagAutoLock: UInt8 = 0x01
    /// Length of one token slot in seconds.
    public static let slotSeconds: Int64 = 30
    /// How many slots either side of the current one are still accepted, which
    /// is thirty minutes at thirty seconds a slot.
    ///
    /// It has to be this wide because of what the phone can and cannot do while
    /// it is idle. The radio repeats the advertisement without any help from the
    /// CPU, so the packets keep arriving all through Doze - but the payload is
    /// built in the application process, and that process gets no CPU at all
    /// while the phone is suspended. Measured on a Galaxy S25: the token stood
    /// still for 99 seconds, and every packet inside that gap was rejected even
    /// though the phone was on the desk at -47 dBm. A minute of tolerance is
    /// enough for clock skew and for nothing else.
    ///
    /// What this costs is the replay window, and it is a smaller loss than it
    /// looks: a replay keeps the Mac **unlocked**, so it has to be broadcast
    /// continuously from a recording no older than this - which means being in
    /// range of the real phone all along, and the RSSI thresholds still have to
    /// be satisfied from wherever the attacker is standing.
    ///
    /// The width is sized against the alarm that republishes the token from the
    /// phone. That alarm is inexact by design, and the system grants it a window:
    /// asked for ten minutes, `dumpsys alarm` reported a latest delivery of about
    /// seventeen. Thirty minutes leaves real headroom over that, which matters on
    /// a vendor ROM free to defer it further still.
    public static let slotTolerance: Int64 = 60
    /// 0xFFFF is reserved for testing, so it needs no Bluetooth SIG assignment.
    public static let manufacturerId: UInt16 = 0xFFFF
    /// Bytes of the truncated HMAC that follow the flags byte. Forty bits are
    /// ample here: a forgery buys nothing but a Mac that fails to lock, and
    /// there is no feedback channel to guess against.
    public static let macLength = 5
    /// `[flags][mac]`, the six bytes that fit next to the service UUID.
    public static let payloadLength = 1 + macLength

    private static let uuidInfo = Data("presence-beacon".utf8)
    private static let tokenInfo = Data("presence-token".utf8)
    /// Domain separator, so an HMAC from this feature can never be mistaken for
    /// one computed anywhere else with the same key material.
    private static let domain = Data("MDS1".utf8)

    // MARK: - Identity

    public static func serviceUUIDBytes(pairingCode: String) -> Data {
        CryptoBox.deriveKey(pairingCode: pairingCode, info: uuidInfo, outputByteCount: 16)
            .withUnsafeBytes { Data($0) }
    }

    /// The derived UUID, used verbatim: the 16 bytes are not massaged into an
    /// RFC 4122 version, because both sides only ever compare them.
    public static func serviceUUID(pairingCode: String) -> UUID {
        let b = [UInt8](serviceUUIDBytes(pairingCode: pairingCode))
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    public static func slot(at date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down)) / slotSeconds
    }

    // MARK: - Payload

    /// The manufacturer specific payload for one slot.
    public static func payload(pairingCode: String, flags: UInt8, slot: Int64) -> Data {
        var out = Data([flags])
        out.append(mac(pairingCode: pairingCode, flags: flags, slot: slot))
        return out
    }

    public static func payload(pairingCode: String, flags: UInt8, at date: Date = Date()) -> Data {
        payload(pairingCode: pairingCode, flags: flags, slot: slot(at: date))
    }

    /// Pulls our payload out of the raw manufacturer data of an advertisement,
    /// which is `[company id, little endian][payload]`. Anything that is not
    /// exactly our beacon comes back as nil.
    public static func payload(fromManufacturerData data: Data) -> Data? {
        guard data.count == 2 + payloadLength else { return nil }
        let bytes = Data(data)
        let company = UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8)
        guard company == manufacturerId else { return nil }
        return Data(bytes.dropFirst(2))
    }

    /// Returns the flags byte of a payload that authenticates, nil otherwise.
    /// A nil here is what keeps a stranger's beacon from arming the auto lock.
    public static func verify(payload: Data, pairingCode: String, at date: Date = Date()) -> UInt8? {
        guard payload.count == payloadLength else { return nil }
        let bytes = Data(payload)
        let flags = bytes[bytes.startIndex]
        let offered = Data(bytes.dropFirst())
        let current = slot(at: date)
        // Derived once rather than once per candidate: the scan runs with
        // duplicates on, so this is a few packets a second, and an HKDF pass for
        // every slot in the window would be wasted work on all of them.
        let key = beaconKey(pairingCode: pairingCode)

        for offset in candidateOffsets {
            let expected = mac(key: key, flags: flags, slot: current + offset)
            // Constant time: the comparison is cheap, but a timing signal here
            // would leak the expected token one byte at a time.
            if constantTimeEquals(expected, offered) { return flags }
        }
        return nil
    }

    /// Slot offsets to try, ordered outwards from the current one. A phone that
    /// is awake and publishing on time matches on the first attempt; only a
    /// payload frozen by Doze pays for the width of the window.
    private static let candidateOffsets: [Int64] = {
        var offsets: [Int64] = [0]
        for distance in 1 ... slotTolerance {
            offsets.append(-distance)
            offsets.append(distance)
        }
        return offsets
    }()

    private static func beaconKey(pairingCode: String) -> SymmetricKey {
        CryptoBox.deriveKey(pairingCode: pairingCode, info: tokenInfo, outputByteCount: 32)
    }

    private static func mac(pairingCode: String, flags: UInt8, slot: Int64) -> Data {
        mac(key: beaconKey(pairingCode: pairingCode), flags: flags, slot: slot)
    }

    private static func mac(key: SymmetricKey, flags: UInt8, slot: Int64) -> Data {
        var message = Data(domain)
        var big = slot.bigEndian
        withUnsafeBytes(of: &big) { message.append(contentsOf: $0) }
        message.append(flags)
        let full = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(full).prefix(macLength)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
