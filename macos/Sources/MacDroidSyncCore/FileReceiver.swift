import CryptoKit
import Foundation

/// Metadata of one incoming file, taken from a `file-offer` message.
public struct FileOffer {
    public let id: String
    public let name: String
    public let size: Int64
    public let mime: String?

    public init(id: String, name: String, size: Int64, mime: String?) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
    }
}

public enum FileTransferError: LocalizedError {
    case tooLarge(Int64)
    case sizeMismatch(expected: Int64, received: Int64)
    case checksumMismatch
    case noTransferInProgress
    case writeFailed(String)
    case readFailed(String)
    case missingFile(String)
    case notAFile(String)
    case refusedByPeer(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let size):
            return "The file is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), the limit is "
                + ByteCountFormatter.string(fromByteCount: Wire.maxFileBytes, countStyle: .file)
        case .sizeMismatch(let expected, let received):
            return "Expected \(expected) bytes but received \(received)"
        case .checksumMismatch:
            return "The checksum does not match, the file was corrupted in transit"
        case .noTransferInProgress:
            return "No file transfer is in progress"
        case .writeFailed(let detail):
            return "Could not write the file: \(detail)"
        case .readFailed(let detail):
            return "Could not read the file: \(detail)"
        case .missingFile(let name):
            return "\(name) is no longer there"
        case .notAFile(let name):
            return "\(name) is a folder, only files can be sent"
        case .refusedByPeer(let detail):
            return detail
        }
    }
}

/// Where an incoming file ends up. Kept as a protocol so `PeerSession` does no
/// file I/O of its own and the tests can watch a transfer without a disk.
public protocol FileSink: AnyObject {
    func begin(_ offer: FileOffer) throws
    func append(_ chunk: Data) throws
    /// Returns the final location of the completed file.
    func finish(sha256: String?) throws -> URL
    func abort()
    /// Bytes written so far for the transfer in flight.
    var receivedBytes: Int64 { get }
}

/// Writes incoming files into a destination directory, by default `~/Downloads`.
///
/// The bytes land in a `<name>.macdroidsync-part` file next to the destination
/// (same volume, so the final rename is atomic) and are only published under the
/// real name once the SHA-256 from `file-end` matches. A name that already
/// exists gets the Finder treatment: `photo.jpg` becomes `photo (2).jpg`.
public final class FileReceiver: FileSink {
    public static let partSuffix = ".macdroidsync-part"

    public let directory: URL

    private let fileManager: FileManager
    private var transfer: Transfer?

    private struct Transfer {
        let offer: FileOffer
        let safeName: String
        let partURL: URL
        let handle: FileHandle
        var digest = SHA256()
        var received: Int64 = 0
    }

    public init(directory: URL = FileReceiver.downloadsDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    public var receivedBytes: Int64 { transfer?.received ?? 0 }
    public var activeName: String? { transfer?.offer.name }

    // MARK: - FileSink

    public func begin(_ offer: FileOffer) throws {
        // A new offer supersedes anything left in flight.
        abort()

        guard offer.size <= Wire.maxFileBytes else { throw FileTransferError.tooLarge(offer.size) }

        let safeName = Self.sanitize(name: offer.name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FileTransferError.writeFailed(error.localizedDescription)
        }

        let partURL = Self.uniqueURL(
            for: directory.appendingPathComponent(safeName + Self.partSuffix),
            fileManager: fileManager
        )
        guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
            throw FileTransferError.writeFailed("could not create \(partURL.lastPathComponent) in \(directory.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            transfer = Transfer(offer: offer, safeName: safeName, partURL: partURL, handle: handle)
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw FileTransferError.writeFailed(error.localizedDescription)
        }
        Log.info("Receiving \(safeName) (\(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)))")
    }

    public func append(_ chunk: Data) throws {
        guard var current = transfer else { throw FileTransferError.noTransferInProgress }
        guard current.received + Int64(chunk.count) <= Wire.maxFileBytes else {
            abort()
            throw FileTransferError.tooLarge(current.received + Int64(chunk.count))
        }
        do {
            try current.handle.write(contentsOf: chunk)
        } catch {
            abort()
            throw FileTransferError.writeFailed(error.localizedDescription)
        }
        current.digest.update(data: chunk)
        current.received += Int64(chunk.count)
        transfer = current
    }

    public func finish(sha256: String?) throws -> URL {
        guard let current = transfer else { throw FileTransferError.noTransferInProgress }
        transfer = nil
        try? current.handle.close()

        func discard(_ error: FileTransferError) -> FileTransferError {
            try? fileManager.removeItem(at: current.partURL)
            return error
        }

        if current.offer.size > 0, current.offer.size != current.received {
            throw discard(.sizeMismatch(expected: current.offer.size, received: current.received))
        }
        let actual = current.digest.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = sha256?.lowercased(), expected != actual {
            throw discard(.checksumMismatch)
        }

        let destination = Self.uniqueURL(
            for: directory.appendingPathComponent(current.safeName),
            fileManager: fileManager
        )
        do {
            try fileManager.moveItem(at: current.partURL, to: destination)
        } catch {
            throw discard(.writeFailed(error.localizedDescription))
        }
        Log.info("Saved \(destination.path) (\(current.received) bytes)")
        return destination
    }

    public func abort() {
        guard let current = transfer else { return }
        transfer = nil
        try? current.handle.close()
        try? fileManager.removeItem(at: current.partURL)
        Log.info("Discarded the partial transfer of \(current.safeName)")
    }

    // MARK: - Names

    /// The peer chooses the file name, so it is never trusted: directories,
    /// `..`, control characters and absurd lengths are all stripped here.
    public static func sanitize(name: String) -> String {
        let withoutDirectories = name.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        var cleaned = String(String.UnicodeScalarView(withoutDirectories.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != ":"
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // Also takes care of ".", ".." and hidden files.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "file" }

        let maximum = 200
        guard cleaned.count > maximum else { return cleaned }
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        if ext.isEmpty || ext.count > 16 {
            return String(cleaned.prefix(maximum))
        }
        return String(base.prefix(maximum - ext.count - 1)) + "." + ext
    }

    /// `photo.jpg` -> `photo (2).jpg` when the name is taken, like Finder does.
    public static func uniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for index in 2 ... 9_999 {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidate)
            if !fileManager.fileExists(atPath: candidateURL.path) { return candidateURL }
        }
        let fallback = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(fallback)
    }
}
