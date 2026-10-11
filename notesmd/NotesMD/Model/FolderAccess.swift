import Foundation
#if os(iOS)
import UIKit
#endif

/// Which folder of notes this device uses, kept between launches. On the Mac
/// its path, which MacDroidSync reads too; on iPad and iPhone a
/// security-scoped bookmark, the only way back into a folder picked once.
enum FolderAccess {
    static let pathKey = "folderPath"
    private static let bookmarkKey = "folderBookmark"
    private static let writerKey = "writer"

    /// This installation's name as a writer of `.notesmd`.
    static var writer: String {
        let defaults = UserDefaults.standard
        if let writer = defaults.string(forKey: writerKey) { return writer }
        #if os(macOS)
        let writer = "mac-" + UUID().uuidString.prefix(8).lowercased() + "-app"
        #else
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let writer = "ios-" + id.prefix(8).lowercased()
        #endif
        defaults.set(writer, forKey: writerKey)
        return writer
    }

    #if os(macOS)
    /// `Notes MD` on iCloud Drive, the folder offered first.
    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Notes MD", isDirectory: true)
    }
    #endif

    static func remember(_ url: URL) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: pathKey)
        #if os(iOS)
        if let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        }
        #endif
    }

    /// The folder chosen before, its access opened again; nil the first time.
    static func restore() -> URL? {
        let defaults = UserDefaults.standard
        #if os(iOS)
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { remember(url) }
        return url
        #else
        guard let path = defaults.string(forKey: pathKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #endif
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
}

#if os(iOS)
/// iPad, where the note's bar at the top holds every command, rather than iPhone.
var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
#endif
