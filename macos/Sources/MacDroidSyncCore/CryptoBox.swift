import CryptoKit
import Foundation

/// Key derivation and AES-256-GCM sealing shared with the Android client.
///
/// key   = HKDF-SHA256(ikm: normalized pairing code, salt: "MacDroidSync/v1",
///                     info: "clipboard-channel", length: 32)
/// nonce = 4 random session bytes || 8 bytes big-endian frame counter
/// body  = nonce || ciphertext || 16 byte GCM tag
public enum CryptoBox {
    public static let hkdfSalt = Data("MacDroidSync/v1".utf8)
    public static let hkdfInfo = Data("clipboard-channel".utf8)
    public static let nonceLength = 12
    public static let tagLength = 16

    /// Pairing codes are compared case insensitively and free of separators,
    /// so "abcd-efgh" and "ABCDEFGH" derive the same key.
    public static func normalize(pairingCode: String) -> String {
        String(pairingCode.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    public static func deriveKey(pairingCode: String) -> SymmetricKey {
        deriveKey(pairingCode: pairingCode, info: hkdfInfo, outputByteCount: 32)
    }

    /// Same pairing code, different purpose: `info` separates the channel key
    /// from the presence beacon material (see `PresenceBeacon`).
    public static func deriveKey(pairingCode: String, info: Data, outputByteCount: Int) -> SymmetricKey {
        let material = SymmetricKey(data: Data(normalize(pairingCode: pairingCode).utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: hkdfSalt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    /// Deterministic sealing, used by the cross platform test vectors.
    public static func seal(plaintext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce))
        var out = Data(nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public static func open(body: Data, key: SymmetricKey) throws -> Data {
        guard body.count > nonceLength + tagLength else {
            throw ProtocolError.malformedFrame("sealed body of \(body.count) bytes is too short")
        }
        let bytes = Data(body)
        let nonce = bytes.prefix(nonceLength)
        let sealed = bytes.dropFirst(nonceLength)
        let ciphertext = sealed.dropLast(tagLength)
        let tag = sealed.suffix(tagLength)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw ProtocolError.authenticationFailed
        }
    }

    /// Human readable pairing code, 16 characters of a confusable free
    /// alphabet grouped as XXXX-XXXX-XXXX-XXXX (80 bits of entropy).
    public static func generatePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var characters: [Character] = []
        var random = SystemRandomNumberGenerator()
        for index in 0 ..< 16 {
            if index > 0 && index % 4 == 0 { characters.append("-") }
            characters.append(alphabet[Int(random.next(upperBound: UInt64(alphabet.count)))])
        }
        return String(characters)
    }

    public static func fingerprint(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Per connection sealing state: an outgoing nonce counter plus replay
/// protection for the sequence numbers seen on the wire.
public final class FrameCodec {
    private let key: SymmetricKey
    private let noncePrefix: Data
    private var sendCounter: UInt64 = 0
    private var lastSeenSeq: UInt64 = 0
    private var outgoingSeq: UInt64 = 0

    public init(pairingCode: String) {
        self.key = CryptoBox.deriveKey(pairingCode: pairingCode)
        var prefix = Data(count: 4)
        prefix.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
        }
        self.noncePrefix = prefix
    }

    public func nextSequence() -> UInt64 {
        outgoingSeq += 1
        return outgoingSeq
    }

    public func seal(_ plaintext: Data) throws -> Data {
        sendCounter += 1
        var nonce = Data(noncePrefix)
        var counter = sendCounter.bigEndian
        withUnsafeBytes(of: &counter) { nonce.append(contentsOf: $0) }
        return try CryptoBox.seal(plaintext: plaintext, key: key, nonce: nonce)
    }

    /// Decrypts a frame body and rejects replayed or reordered messages.
    public func open(_ body: Data) throws -> Message {
        let plaintext = try CryptoBox.open(body: body, key: key)
        let message = try Message.decode(plaintext)
        guard message.seq > lastSeenSeq else {
            throw ProtocolError.replayDetected(message.seq)
        }
        lastSeenSeq = message.seq
        return message
    }
}
