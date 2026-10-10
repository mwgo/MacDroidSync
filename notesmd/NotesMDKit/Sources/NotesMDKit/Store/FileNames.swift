import Foundation

/// How notes and their attachments are named in the folder of notes:
/// `Folder/Title.md` with the pictures and files in `Folder/Title.assets/`.
public enum FileNames {
    public static let noteExtension = "md"
    public static let assetsSuffix = ".assets"
    /// The hidden folder of what Markdown cannot hold.
    public static let metaFolder = ".notesmd"
    /// What an empty title becomes, as on the phone.
    public static let untitled = "New note"

    /// The name of a note's file without its extension, from its title: no `/`
    /// or `:`, no leading dot, no control characters, NFC, not too long.
    public static func base(forTitle title: String) -> String {
        var name = title.precomposedStringWithCanonicalMapping
            .map { c -> Character in
                if c == "/" || c == ":" || c == "\\" { return "-" }
                if c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { return " " }
                return c
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.utf8.count > 150 {
            while name.utf8.count > 150 { name.removeLast() }
            name = name.trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? untitled : name
    }

    /// A folder name the file system takes.
    public static func folderName(_ name: String) -> String {
        let clean = base(forTitle: name)
        return clean.hasSuffix(assetsSuffix) ? String(clean.dropLast(assetsSuffix.count)) + "-assets" : clean
    }

    /// `base`, or `base 2`, `base 3`… whichever `taken` does not hold, compared without case.
    public static func unique(_ base: String, taken: Set<String>) -> String {
        let lower = Set(taken.map { $0.lowercased() })
        if !lower.contains(base.lowercased()) { return base }
        var n = 2
        while lower.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Whether `name` is `base` or `base N`, a name `unique` could have given for it.
    public static func isVariant(_ name: String, of base: String) -> Bool {
        if name.caseInsensitiveCompare(base) == .orderedSame { return true }
        guard name.lowercased().hasPrefix(base.lowercased() + " ") else { return false }
        let rest = name.dropFirst(base.count + 1)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    public static func assetsFolder(forBase base: String) -> String { base + assetsSuffix }

    // MARK: - Links

    private static let linkUnsafe: CharacterSet = {
        var set = CharacterSet(charactersIn: " ()[]<>%#?\"")
        set.formUnion(.controlCharacters)
        set.formUnion(.newlines)
        return set
    }()

    /// A relative path as it stands in a Markdown link: what a link cannot hold
    /// percent-encoded, letters of any script kept as they are.
    public static func encodeLink(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if linkUnsafe.contains(scalar) {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func decodeLink(_ link: String) -> String {
        (link.removingPercentEncoding ?? link).precomposedStringWithCanonicalMapping
    }
}
