import CryptoKit
import Foundation

/// A note as the phone holds it, against the same note in the folder.
///
/// The phone keeps every picture as `images/<uuid>.<ext>` and every file as
/// `files/<uuid>/<name>`, all notes together; the folder keeps them next to
/// the note, in `Title.assets/<uuid>.<ext>` and `Title.assets/<uuid>/<name>`.
/// The rest of the Markdown is the same on both sides.
public enum WireForm {
    public static let images = "images/"
    public static let files = MdFile.folder

    /// The phone's form of a note whose attachments are in `assetsFolder`
    /// (the folder's name, e.g. `Title.assets`), and for each attachment its
    /// phone path with its path relative to the note's folder.
    public static func toWire(_ markdown: String, assetsFolder: String) -> (markdown: String, assets: [(wire: String, local: String)]) {
        var assets: [(String, String)] = []
        var seen = Set<String>()
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            guard let link = Markdown.parseImage(line)?.path ?? Markdown.parseFile(line)?.path else { return line }
            let local = FileNames.decodeLink(link)
            guard let wire = wirePath(local, assetsFolder: assetsFolder) else { return line }
            if seen.insert(wire).inserted { assets.append((wire, local)) }
            return replaceLink(in: line, from: link, to: wire)
        }
        return (lines.joined(separator: "\n"), assets)
    }

    /// The folder's form of a note the phone sent, its attachments to go into `assetsFolder`.
    public static func fromWire(_ markdown: String, assetsFolder: String) -> String {
        markdown.components(separatedBy: "\n").map { line -> String in
            guard let link = Markdown.parseImage(line)?.path ?? Markdown.parseFile(line)?.path,
                  let local = localPath(link, assetsFolder: assetsFolder) else { return line }
            return replaceLink(in: line, from: link, to: FileNames.encodeLink(local))
        }.joined(separator: "\n")
    }

    /// `Title.assets/<uuid>.jpg` → `images/<uuid>.jpg`, `Title.assets/<uuid>/a.pdf` → `files/<uuid>/a.pdf`.
    public static func wirePath(_ local: String, assetsFolder: String) -> String? {
        let prefix = assetsFolder.precomposedStringWithCanonicalMapping + "/"
        let path = local.precomposedStringWithCanonicalMapping
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.isEmpty, !rest.contains("..") else { return nil }
        return (rest.contains("/") ? files : images) + rest
    }

    /// The other way round; nil for a path that is not the phone's.
    public static func localPath(_ wire: String, assetsFolder: String) -> String? {
        guard !wire.contains("..") else { return nil }
        if wire.hasPrefix(images) { return assetsFolder + "/" + wire.dropFirst(images.count) }
        if wire.hasPrefix(files) { return assetsFolder + "/" + wire.dropFirst(files.count) }
        return nil
    }

    /// The drawing's strokes that go with a picture: `x.png` → `x.json`.
    public static func strokesPath(_ imagePath: String) -> String {
        guard let dot = imagePath.lastIndex(of: "."), !imagePath[dot...].contains("/") else { return imagePath + ".json" }
        return imagePath[..<dot] + ".json"
    }

    static func replaceLink(in line: String, from: String, to: String) -> String {
        guard let range = line.range(of: "](" + from + ")", options: .backwards) else { return line }
        return line.replacingCharacters(in: range, with: "](" + to + ")")
    }
}

/// What tells a change of a note, the same formula as on the phone: the
/// Markdown, then for every attachment `\n<path>:<sha256>`.
public enum NoteHash {
    public static func hash(markdown: String, assets: [(path: String, sha256: String)]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(markdown.utf8))
        for asset in assets { hasher.update(data: Data("\n\(asset.path):\(asset.sha256)".utf8)) }
        return hex(hasher.finalize())
    }

    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    public static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
