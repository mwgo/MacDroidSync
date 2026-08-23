import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// One outgoing file: reads it in `Wire.fileChunkBytes` slices and hashes it on
/// the way out, so nothing bigger than a chunk is ever held in memory.
///
/// The pump lives in `PeerSession`: it asks for the next chunk only after the
/// previous one has been handed to the network, which is what keeps a 500 MB
/// transfer flat on memory.
public final class FileSender {
    public let id: String
    public let url: URL
    public let name: String
    public let size: Int64
    public let mime: String?

    private let handle: FileHandle
    private var digest = SHA256()
    private var sent: Int64 = 0
    private var isFinished = false

    public private(set) var isCancelled = false

    public init(url: URL, id: String = UUID().uuidString) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FileTransferError.missingFile(url.lastPathComponent)
        }
        guard !isDirectory.boolValue else {
            throw FileTransferError.notAFile(url.lastPathComponent)
        }

        let attributes = try? manager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Wire.maxFileBytes else { throw FileTransferError.tooLarge(size) }

        do {
            self.handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileTransferError.readFailed(error.localizedDescription)
        }
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.size = size
        self.mime = FileSender.mimeType(of: url)
    }

    public var sentBytes: Int64 { sent }

    /// Next slice of the file, or nil once everything has been read.
    public func nextChunk() throws -> Data? {
        guard !isFinished else { return nil }
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: Wire.fileChunkBytes)
        } catch {
            throw FileTransferError.readFailed(error.localizedDescription)
        }
        guard let chunk, !chunk.isEmpty else {
            isFinished = true
            return nil
        }
        digest.update(data: chunk)
        sent += Int64(chunk.count)
        return chunk
    }

    /// Lowercase hex SHA-256 of everything that was read, for `file-end`.
    public func checksum() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func cancel() {
        isCancelled = true
        close()
    }

    public func close() {
        try? handle.close()
    }

    private static func mimeType(of url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return type.preferredMIMEType
    }
}
