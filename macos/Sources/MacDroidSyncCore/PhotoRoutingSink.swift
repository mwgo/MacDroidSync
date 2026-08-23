import Foundation
import UniformTypeIdentifiers

/// Decides where an incoming transfer goes: the Downloads folder, as before, or
/// the Photos library.
///
/// It is a `FileSink` wrapping two of them, so `PeerSession` keeps doing no file
/// I/O of its own and the existing, tested part-file discipline - size checks,
/// SHA-256 verification, atomic rename - is reused for photos rather than
/// written a second time. What is new here is only the routing and what happens
/// after the bytes have landed.
public final class PhotoRoutingSink: FileSink {

    private enum Route {
        case file
        case photo(FileOffer)
    }

    private let downloads: FileSink
    private let staging: FileReceiver
    private let importer: PhotoImporter
    private let acceptsPhotos: () -> Bool
    private var route: Route = .file

    /// Reported when a photo's bytes were fine but Photos would not take it.
    public var onImportFailed: ((String, String) -> Void)?

    public init(
        downloads: FileSink,
        importer: PhotoImporter,
        stagingDirectory: URL = PhotoRoutingSink.stagingDirectory,
        acceptsPhotos: @escaping () -> Bool
    ) {
        self.downloads = downloads
        self.staging = FileReceiver(directory: stagingDirectory)
        self.importer = importer
        self.acceptsPhotos = acceptsPhotos
    }

    /// Beside the support directory, not in a temporary one: a staged file has to
    /// survive a crash so the import can simply be tried again.
    public static var stagingDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("photo-staging", isDirectory: true)
    }

    // MARK: - FileSink

    public func begin(_ offer: FileOffer) throws {
        guard let key = offer.photoKey, acceptsPhotos() else {
            route = .file
            try downloads.begin(offer)
            return
        }
        // A gallery item has its own ceiling: the photo path streams, so the
        // limit is policy rather than memory.
        guard offer.size <= Wire.maxPhotoBytes else {
            throw FileTransferError.tooLarge(offer.size)
        }
        let verdict = importer.accepts(key: key, sha256: nil)
        guard verdict.accepted else {
            throw PhotoLibraryError.importFailed(verdict.reason ?? "this Mac does not want it")
        }
        route = .photo(offer)
        try staging.begin(offer)
    }

    public func append(_ chunk: Data) throws {
        switch route {
        case .file: try downloads.append(chunk)
        case .photo: try staging.append(chunk)
        }
    }

    public func finish(sha256: String?) throws -> URL {
        switch route {
        case .file:
            return try downloads.finish(sha256: sha256)
        case .photo(let offer):
            let staged = try staging.finish(sha256: sha256)
            // Handing it to Photos happens off this thread: this is the session's
            // queue, and a half gigabyte video would stall the heartbeat and drop
            // the connection. The phone is told the bytes arrived, which is true;
            // if Photos then refuses, the index records nothing and the next
            // manifest offers the photo again, which is the self-healing path.
            importer.enqueueImport(
                stagedFile: staged,
                offer: offer,
                sha256: sha256 ?? "",
                onFailure: { [weak self] name, reason in
                    self?.onImportFailed?(name, reason)
                }
            )
            return staged
        }
    }

    public func abort() {
        switch route {
        case .file: downloads.abort()
        case .photo: staging.abort()
        }
    }

    public var receivedBytes: Int64 {
        switch route {
        case .file: return downloads.receivedBytes
        case .photo: return staging.receivedBytes
        }
    }

    /// A staged photo's path would be a lie to show the phone: the file is on its
    /// way into the library and about to be deleted. So the answer is where the
    /// photo actually went.
    public func describe(_ url: URL) -> String {
        switch route {
        case .file: return downloads.describe(url)
        case .photo: return "Photos"
        }
    }
}

public extension PhotoImporter {

    /// Whether a name looks like something Photos takes as a video rather than a
    /// still. The extension is trusted over the phone's `mime`, which the
    /// protocol itself describes as informational.
    static func isVideo(name: String, mime: String?) -> Bool {
        if let type = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()) {
            if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
            if type.conforms(to: .image) { return false }
        }
        return mime?.hasPrefix("video/") ?? false
    }

    /// Imports off the caller's thread. Errors are reported rather than thrown:
    /// by the time this runs, the transfer has already been acknowledged.
    func enqueueImport(
        stagedFile: URL,
        offer: FileOffer,
        sha256: String,
        onFailure: @escaping (String, String) -> Void
    ) {
        guard let key = offer.photoKey else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.store(
                    stagedFile: stagedFile,
                    key: key,
                    filename: offer.name,
                    sha256: sha256,
                    size: offer.size,
                    captureAt: offer.captureAt ?? 0,
                    isVideo: PhotoImporter.isVideo(name: offer.name, mime: offer.mime)
                )
            } catch {
                // The staged file stays where it is: it is verified bytes, and a
                // retry is cheaper than another transfer.
                Log.error("Photos would not take \(offer.name): \(error.localizedDescription)")
                onFailure(offer.name, error.localizedDescription)
            }
        }
    }
}
