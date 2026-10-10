import Foundation

/// Finding notes by what they say, as on the phone (NoteSearch.kt). Case and
/// Polish marks do not count, so "zolw" finds "żółw"; every word of the query
/// has to be there, in any order. Folding keeps one UTF-16 unit for one, so
/// that where a word is found in the folded text is where it is in the text.
public enum NoteSearch {

    public static func fold(_ text: String) -> [UInt16] {
        text.utf16.map(foldUnit)
    }

    private static func foldUnit(_ u: UInt16) -> UInt16 {
        switch u {
        case 0x0142, 0x0141: return 0x6C // ł Ł
        case 0x00DF: return 0x73 // ß
        default: break
        }
        guard !UTF16.isLeadSurrogate(u), !UTF16.isTrailSurrogate(u), let scalar = Unicode.Scalar(u) else { return u }
        let lower = String(Character(scalar)).lowercased()
        guard let first = lower.unicodeScalars.first, lower.unicodeScalars.count == 1 || first.value < 0x80 else { return u }
        if first.value < 0x80 { return UInt16(first.value) }
        let bare = lower.decomposedStringWithCanonicalMapping.unicodeScalars.first ?? first
        return bare.value <= 0xFFFF ? UInt16(bare.value) : u
    }

    /// The words of a query, folded; empty when there is nothing to look for.
    public static func words(_ query: String) -> [[UInt16]] {
        let folded = String(utf16CodeUnits: fold(query), count: query.utf16.count)
        return folded.split(whereSeparator: { $0.isWhitespace }).map { Array(String($0).utf16) }
    }

    public static func matches(_ text: String, _ words: [[UInt16]]) -> Bool {
        if words.isEmpty { return true }
        let folded = fold(text)
        return words.allSatisfy { find($0, in: folded, from: 0) != nil }
    }

    /// Where each word is found in `text`, as UTF-16 ranges.
    public static func hits(_ text: String, _ words: [[UInt16]]) -> [Range<Int>] {
        let folded = fold(text)
        var hits: [Range<Int>] = []
        for word in words where !word.isEmpty {
            var at = find(word, in: folded, from: 0)
            while let start = at {
                hits.append(start..<(start + word.count))
                at = find(word, in: folded, from: start + word.count)
            }
        }
        return hits
    }

    /// A piece of `text` around the first word found, cut at whole words and
    /// marked with an ellipsis where it was cut, or nil when none is found.
    public static func snippet(_ text: String, _ words: [[UInt16]], before: Int = 40, length: Int = 200) -> String? {
        guard let first = hits(text, words).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let units = Array(text.utf16)
        var start = max(first.lowerBound - before, 0)
        if start > 0, let space = units[start..<first.lowerBound].firstIndex(of: 0x20) { start = space + 1 }
        let end = min(start + length, units.count)
        let piece = String(utf16CodeUnits: Array(units[start..<end]), count: end - start).trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > 0 ? "…" : "") + piece + (end < units.count ? "…" : "")
    }

    private static func find(_ word: [UInt16], in text: [UInt16], from: Int) -> Int? {
        guard !word.isEmpty, text.count >= word.count, from <= text.count - word.count else { return nil }
        var i = from
        while i <= text.count - word.count {
            if text[i] == word[0], text[i..<(i + word.count)].elementsEqual(word) { return i }
            i += 1
        }
        return nil
    }
}
