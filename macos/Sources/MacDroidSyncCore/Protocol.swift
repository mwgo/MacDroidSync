import Foundation

/// Wire protocol shared by the macOS and the Android side.
///
/// Frame layout:  [4 bytes big-endian length N][1 byte kind][N - 1 bytes body]
/// The only frame allowed in plaintext is the server challenge; every other
/// frame carries an AES-256-GCM sealed box (see `FrameCodec`).
public enum Wire {
    public static let version = 1
    public static let defaultPort: UInt16 = 47831
    public static let bonjourServiceType = "_macdroidsync._tcp"

    /// Hard limit for a single frame, protects against a hostile length prefix.
    public static let maxFrameSize = 4 * 1024 * 1024
    /// Clipboard payloads above this size are skipped instead of being synced.
    public static let maxClipboardBytes = 512 * 1024

    public static let heartbeatInterval: TimeInterval = 15
    public static let receiveTimeout: TimeInterval = 30
}

public enum FrameKind: UInt8 {
    case plaintext = 0x01
    case encrypted = 0x02
}

public enum MessageType {
    public static let challenge = "challenge"
    public static let hello = "hello"
    public static let helloAck = "hello-ack"
    public static let clipboard = "clipboard"
    public static let clipboardAck = "clipboard-ack"
    public static let requestClipboard = "request-clipboard"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let heartbeat = "heartbeat"
    public static let bye = "bye"
}

/// One protocol message. Absent fields are omitted from the JSON payload.
public struct Message: Codable {
    public var v: Int
    public var seq: UInt64
    public var type: String
    public var ts: Int64
    public var text: String?
    public var device: String?
    public var deviceId: String?
    public var challenge: String?
    public var token: UInt64?
    public var reason: String?

    public init(
        v: Int = Wire.version,
        seq: UInt64 = 0,
        type: String,
        ts: Int64 = Message.now(),
        text: String? = nil,
        device: String? = nil,
        deviceId: String? = nil,
        challenge: String? = nil,
        token: UInt64? = nil,
        reason: String? = nil
    ) {
        self.v = v
        self.seq = seq
        self.type = type
        self.ts = ts
        self.text = text
        self.device = device
        self.deviceId = deviceId
        self.challenge = challenge
        self.token = token
        self.reason = reason
    }

    public static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: data)
    }
}

public enum ProtocolError: LocalizedError {
    case frameTooLarge(Int)
    case malformedFrame(String)
    case unexpectedFrame(String)
    case authenticationFailed
    case replayDetected(UInt64)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size):
            return "Frame of \(size) bytes exceeds the maximum frame size"
        case .malformedFrame(let detail):
            return "Malformed frame: \(detail)"
        case .unexpectedFrame(let detail):
            return "Unexpected frame: \(detail)"
        case .authenticationFailed:
            return "Authentication failed - the pairing code does not match"
        case .replayDetected(let seq):
            return "Replayed or out of order message (seq \(seq))"
        }
    }
}

/// Builds and parses the length-prefixed framing used on the socket.
public enum Framing {
    public static func frame(kind: FrameKind, body: Data) -> Data {
        var out = Data(capacity: body.count + 5)
        let length = UInt32(body.count + 1)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(kind.rawValue)
        out.append(body)
        return out
    }

    /// Pulls the first complete frame out of `buffer`, removing its bytes.
    /// Returns nil when more bytes are needed.
    public static func nextFrame(from buffer: inout Data) throws -> (kind: FrameKind, body: Data)? {
        guard buffer.count >= 4 else { return nil }
        let header = [UInt8](buffer.prefix(4))
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length >= 1 else { throw ProtocolError.malformedFrame("zero length") }
        guard length <= Wire.maxFrameSize else { throw ProtocolError.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }

        let payload = Data(buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + length])
        buffer.removeFirst(4 + length)

        guard let kind = FrameKind(rawValue: payload[payload.startIndex]) else {
            throw ProtocolError.malformedFrame("unknown frame kind \(payload[payload.startIndex])")
        }
        return (kind, Data(payload.dropFirst()))
    }
}
