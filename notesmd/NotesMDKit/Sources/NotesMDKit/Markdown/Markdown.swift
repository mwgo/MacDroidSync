import Foundation

// The Markdown of the notes, the same dialect the phone's editor reads and
// writes (android/.../Markdown.kt): one block per line, nested lists, fenced
// code, tables, pictures and files on lines of their own, and `*` `**` `__` `
// inside a line. Offsets are in UTF-16 units, as NSString and NSAttributedString count.

public enum BlockType: String, Codable, Sendable {
    case paragraph, bullet, numbered, checkbox, quote, heading, code, table, image, file
}

public enum InlineKind: String, Codable, Sendable {
    case italic, bold, underline, code
}

/// `level` is a heading's; `depth` how far a list item is nested, 0 for the outermost.
public struct Block: Equatable, Hashable, Sendable {
    public var type: BlockType
    public var level: Int
    public var checked: Bool
    public var depth: Int

    public init(_ type: BlockType, level: Int = 0, checked: Bool = false, depth: Int = 0) {
        self.type = type
        self.level = level
        self.checked = checked
        self.depth = depth
    }

    public static let paragraph = Block(.paragraph)

    public var isListItem: Bool { Block.listItems.contains(type) }

    public static let listItems: Set<BlockType> = [.bullet, .numbered, .checkbox]

    /// How deep lists nest, the outermost level not counted.
    public static let maxDepth = 5
}

/// Counts the items of numbered lists, each level of a nested list on its own.
public struct ListNumbers {
    private var counts = [Int](repeating: 0, count: Block.maxDepth + 1)

    public init() {}

    /// The number of the line's item in its list, 0 for a line that is not a numbered item.
    public mutating func next(_ block: Block) -> Int {
        guard block.isListItem else {
            counts = [Int](repeating: 0, count: Block.maxDepth + 1)
            return 0
        }
        let depth = min(max(block.depth, 0), Block.maxDepth)
        for d in (depth + 1)..<counts.count { counts[d] = 0 }
        guard block.type == .numbered else {
            counts[depth] = 0
            return 0
        }
        counts[depth] += 1
        return counts[depth]
    }
}

/// A style over `start..<end` of a line's text, the delimiters already taken out.
public struct InlineStyle: Equatable, Hashable, Sendable {
    public var kind: InlineKind
    public var start: Int
    public var end: Int

    public init(_ kind: InlineKind, _ start: Int, _ end: Int) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// A table without a header: every row is alike. Markdown insists on one, so
/// the first row is written above the separator line and read back from there.
public struct MdTable: Equatable, Hashable, Sendable {
    public var rows: [[String]]

    public init(rows: [[String]]) {
        self.rows = rows
    }

    public var columns: Int { rows.map(\.count).max() ?? 0 }
}

/// A picture on a line of its own: `![alt](path)`; a drawing has the alt "drawing".
public struct MdImage: Equatable, Hashable, Sendable {
    public var path: String
    public var alt: String

    public init(path: String, alt: String = "") {
        self.path = path
        self.alt = alt
    }

    public var isDrawing: Bool { alt == MdImage.drawingAlt }

    public static let drawingAlt = "drawing"
}

/// A file attached on a line of its own: `[name](path)`. On the phone the path
/// is under `files/`; in the folder of notes it is in the note's `.assets` folder.
public struct MdFile: Equatable, Hashable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    public var fileExtension: String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = last.lastIndex(of: ".") else { return "" }
        return last[last.index(after: dot)...].lowercased()
    }

    public var isAudio: Bool { MdFile.audio.contains(fileExtension) }

    /// Where the phone keeps attached files.
    public static let folder = "files/"

    static let audio: Set<String> = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "amr", "flac", "3gp"]

    /// Whether a link points at an attached file rather than anywhere else.
    public static func isAttachment(_ path: String) -> Bool {
        !path.contains("://") && (path.hasPrefix(folder) || path.contains(FileNames.assetsSuffix + "/"))
    }
}

public struct MdLine: Equatable, Hashable, Sendable {
    public var block: Block
    public var text: String
    public var styles: [InlineStyle]
    public var table: MdTable?
    public var image: MdImage?
    public var file: MdFile?

    public init(_ block: Block, _ text: String = "", styles: [InlineStyle] = [], table: MdTable? = nil, image: MdImage? = nil, file: MdFile? = nil) {
        self.block = block
        self.text = text
        self.styles = styles
        self.table = table
        self.image = image
        self.file = file
    }

    /// Nothing written in it, nor anything shown.
    public var isBlank: Bool {
        table == nil && image == nil && file == nil && text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A pair of delimiters the character just typed has closed. Offsets are within
/// the line: the opening delimiter starts at `openStart`, the closing one at
/// `closeStart`, and both are `delimiter` units long.
public struct InlineMatch: Equatable, Sendable {
    public var kind: InlineKind
    public var openStart: Int
    public var closeStart: Int
    public var delimiter: Int
}

public enum Markdown {

    /// What each level of a nested list is indented by.
    public static let indent = "    "

    private static let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6}) ")
    private static let checkboxPattern = try! NSRegularExpression(pattern: "^(?:[-*] )?\\[([ xX]?)\\] ")
    private static let bulletPattern = try! NSRegularExpression(pattern: "^[-*] ")
    private static let numberedPattern = try! NSRegularExpression(pattern: "^\\d+\\. ")
    private static let quotePattern = try! NSRegularExpression(pattern: "^>( |$)")
    private static let separatorCell = try! NSRegularExpression(pattern: "^:?-+:?$")
    private static let imagePattern = try! NSRegularExpression(pattern: "^\\s*!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)\\s*$")
    private static let linkPattern = try! NSRegularExpression(pattern: "^\\s*\\[([^\\]]*)\\]\\(([^)\\s]+)\\)\\s*$")

    private static func match(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func group(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        let range = result.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (text as NSString).substring(with: range)
    }

    /// The picture a line consists of, or nil when it is anything else.
    public static func parseImage(_ line: String) -> MdImage? {
        guard let m = match(imagePattern, line) else { return nil }
        return MdImage(path: group(m, 2, in: line), alt: group(m, 1, in: line))
    }

    /// The attached file a line consists of; a link anywhere else is ordinary text.
    public static func parseFile(_ line: String) -> MdFile? {
        guard let m = match(linkPattern, line) else { return nil }
        let path = group(m, 2, in: line)
        guard MdFile.isAttachment(path) else { return nil }
        return MdFile(path: path, name: group(m, 1, in: line))
    }

    public static func fileToMarkdown(_ file: MdFile) -> String {
        let name = file.name.map { "[]\n".contains($0) ? " " : $0 }
        return "[" + String(name).trimmingCharacters(in: .whitespaces) + "](" + file.path + ")"
    }

    public static func imageToMarkdown(_ image: MdImage) -> String {
        "![\(image.alt)](\(image.path))"
    }

    /// The paragraph mode a line starts with, and how many UTF-16 units say so.
    public static func detectBlockPrefix(_ line: String) -> (Block, Int)? {
        if let m = match(headingPattern, line) {
            return (Block(.heading, level: m.range(at: 1).length), m.range.length)
        }
        if let m = match(checkboxPattern, line) {
            let mark = group(m, 1, in: line).trimmingCharacters(in: .whitespaces)
            return (Block(.checkbox, checked: !mark.isEmpty), m.range.length)
        }
        if let m = match(bulletPattern, line) { return (Block(.bullet), m.range.length) }
        if let m = match(numberedPattern, line) { return (Block(.numbered), m.range.length) }
        if let m = match(quotePattern, line) { return (Block(.quote), m.range.length) }
        return nil
    }

    /// The cells of `| a | b |`, or nil when the line is not a table row.
    public static func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        return trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = parseTableRow(line) else { return false }
        return cells.allSatisfy { match(separatorCell, $0) != nil }
    }

    /// Whether the line opens or closes a fenced code block.
    public static func isFence(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```")
    }

    // MARK: - Inline

    /// Whether the unit before `cursor` closes `*x*`, `_x_`, `**x**`, `__x__`
    /// or `` `x` ``. The text between may not be empty nor start or end with a
    /// space, and a single delimiter never pairs with half of a double one.
    /// Nothing is matched inside or across code.
    public static func findClosedInline(_ line: String, cursor: Int) -> InlineMatch? {
        let s = Array(line.utf16)
        guard cursor >= 1, cursor <= s.count else { return nil }
        let c = s[cursor - 1]
        if c == tick {
            guard cursor >= 2, let open = lastIndex(of: tick, in: s, upTo: cursor - 2), open != cursor - 2 else { return nil }
            return InlineMatch(kind: .code, openStart: open, closeStart: cursor - 1, delimiter: 1)
        }
        guard c == star || c == underscore else { return nil }
        let delimiter = cursor >= 2 && s[cursor - 2] == c ? 2 : 1
        let closeStart = cursor - delimiter
        guard closeStart >= 1, !isSpace(s[closeStart - 1]), s[closeStart - 1] != c else { return nil }
        if s[0..<closeStart].filter({ $0 == tick }).count % 2 == 1 { return nil }
        var j = closeStart - 1
        while j >= 0 {
            let ch = s[j]
            if ch == tick { return nil }
            if ch != c {
                j -= 1
                continue
            }
            var runStart = j
            while runStart > 0, s[runStart - 1] == c { runStart -= 1 }
            if j - runStart + 1 == delimiter {
                let contentStart = runStart + delimiter
                let wordBoundary = c != underscore || runStart == 0 || !isWordChar(s[runStart - 1])
                if contentStart < closeStart, !isSpace(s[contentStart]), wordBoundary {
                    return InlineMatch(kind: kindOf(c, delimiter), openStart: runStart, closeStart: closeStart, delimiter: delimiter)
                }
            }
            j = runStart - 1
        }
        return nil
    }

    /// A line's text with the inline delimiters taken out, and the styles they stood for.
    public static func parseInline(_ source: String) -> (String, [InlineStyle]) {
        let (units, styles) = parseInline(Array(source.utf16))
        return (String(utf16CodeUnits: units, count: units.count), styles)
    }

    private static func parseInline(_ s: [UInt16]) -> ([UInt16], [InlineStyle]) {
        var out: [UInt16] = []
        var styles: [InlineStyle] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == tick {
                if let close = firstIndex(of: tick, in: s, from: i + 1), close > i + 1 {
                    styles.append(InlineStyle(.code, out.count, out.count + close - i - 1))
                    out.append(contentsOf: s[(i + 1)..<close])
                    i = close + 1
                    continue
                }
            } else if c == star || c == underscore {
                let delimiter = i + 1 < s.count && s[i + 1] == c ? 2 : 1
                if let close = findClose(s, open: i, c: c, delimiter: delimiter) {
                    let (inner, innerStyles) = parseInline(Array(s[(i + delimiter)..<close]))
                    let start = out.count
                    out.append(contentsOf: inner)
                    styles.append(contentsOf: innerStyles.map { InlineStyle($0.kind, $0.start + start, $0.end + start) })
                    styles.append(InlineStyle(kindOf(c, delimiter), start, out.count))
                    i = close + delimiter
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return (out, styles)
    }

    private static func findClose(_ s: [UInt16], open: Int, c: UInt16, delimiter: Int) -> Int? {
        let from = open + delimiter
        guard from < s.count, !isSpace(s[from]) else { return nil }
        if c == underscore, open > 0, isWordChar(s[open - 1]) { return nil }
        var j = from + 1
        while j < s.count {
            let ch = s[j]
            if ch == tick, let end = firstIndex(of: tick, in: s, from: j + 1), end > j + 1 {
                j = end + 1
                continue
            }
            if ch == c {
                var run = 1
                while j + run < s.count, s[j + run] == c { run += 1 }
                if run == delimiter, !isSpace(s[j - 1]) { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    /// The text of one line of inline Markdown without its delimiters.
    public static func inlineText(_ source: String) -> String {
        parseInline(source).0
    }

    /// Puts the delimiters back. Styles that overlap without nesting are closed
    /// and reopened around each other, so the result always parses again.
    public static func inlineToMarkdown(_ text: String, _ styles: [InlineStyle]) -> String {
        let s = Array(text.utf16)
        let spans = styles.filter { $0.start < $0.end }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var out: [UInt16] = []
        var open: [InlineStyle] = []
        for i in 0...s.count {
            if let closing = open.firstIndex(where: { $0.end <= i }) {
                let above = Array(open[closing...])
                for style in above.reversed() { out.append(contentsOf: delimiterOf(style.kind)) }
                open.removeLast(above.count)
                for style in above where style.end > i {
                    out.append(contentsOf: delimiterOf(style.kind))
                    open.append(style)
                }
            }
            for style in spans where style.start == i {
                out.append(contentsOf: delimiterOf(style.kind))
                open.append(style)
            }
            if i < s.count { out.append(s[i]) }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    private static func kindOf(_ c: UInt16, _ delimiter: Int) -> InlineKind {
        if delimiter == 1 { return .italic }
        return c == star ? .bold : .underline
    }

    public static func delimiter(of kind: InlineKind) -> String {
        switch kind {
        case .italic: return "*"
        case .bold: return "**"
        case .underline: return "__"
        case .code: return "`"
        }
    }

    private static func delimiterOf(_ kind: InlineKind) -> [UInt16] { Array(delimiter(of: kind).utf16) }

    private static let tick = UInt16(UInt8(ascii: "`"))
    private static let star = UInt16(UInt8(ascii: "*"))
    private static let underscore = UInt16(UInt8(ascii: "_"))

    private static func scalar(_ u: UInt16) -> Unicode.Scalar? {
        UTF16.isLeadSurrogate(u) || UTF16.isTrailSurrogate(u) ? nil : Unicode.Scalar(u)
    }

    static func isSpace(_ u: UInt16) -> Bool {
        guard let scalar = scalar(u) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func isWordChar(_ u: UInt16) -> Bool {
        guard let scalar = scalar(u) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func firstIndex(of c: UInt16, in s: [UInt16], from: Int) -> Int? {
        guard from < s.count else { return nil }
        return s[from...].firstIndex(of: c)
    }

    private static func lastIndex(of c: UInt16, in s: [UInt16], upTo: Int) -> Int? {
        guard upTo >= 0 else { return nil }
        return s[0...min(upTo, s.count - 1)].lastIndex(of: c)
    }

    // MARK: - Sections

    /// The first line after the heading at `index` that ends its section: the
    /// next heading of the same or a higher level, or the end of the note.
    /// `levels` holds each line's heading level, 0 for any other line.
    public static func sectionEnd(_ levels: [Int], _ index: Int) -> Int {
        let level = levels[index]
        var i = index + 1
        while i < levels.count {
            if levels[i] >= 1, levels[i] <= level { return i }
            i += 1
        }
        return levels.count
    }

    // MARK: - Whole notes

    /// How many columns of indent a line starts with, a tab counting as four, and how many characters that is.
    private static func indentOf(_ line: String) -> (columns: Int, units: Int) {
        var columns = 0
        var units = 0
        for c in line.utf16 {
            if c == 0x20 {
                columns += 1
            } else if c == 0x09 {
                columns += indent.count
            } else {
                break
            }
            units += 1
        }
        return (columns, units)
    }

    /// How deep a list item indented by `columns` is, given the indents of the
    /// items open above it: deeper than the one above when it is indented
    /// further, however far, and back at the level it lines up with otherwise.
    private static func depthOf(_ open: inout [Int], _ columns: Int) -> Int {
        while let last = open.last, last > columns { open.removeLast() }
        if open.last.map({ $0 < columns }) ?? true { open.append(columns) }
        return min(open.count - 1, Block.maxDepth)
    }

    private static func dropUnits(_ line: String, _ count: Int) -> String {
        (line as NSString).substring(from: min(count, (line as NSString).length))
    }

    public static func parse(_ markdown: String) -> [MdLine] {
        let source = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var lines: [MdLine] = []
        var indents: [Int] = []
        var i = 0
        while i < source.count {
            let line = source[i]
            let (columns, units) = indentOf(line)
            let body = dropUnits(line, units)
            if let item = detectBlockPrefix(body), item.0.isListItem {
                let (text, styles) = parseInline(dropUnits(body, item.1))
                var block = item.0
                block.depth = depthOf(&indents, columns)
                lines.append(MdLine(block, text, styles: styles))
                i += 1
                continue
            }
            indents.removeAll()
            if isFence(line) {
                // The lines up to the closing fence, or to the end of a note that never closes it, as they are.
                let start = lines.count
                i += 1
                while i < source.count, !isFence(source[i]) {
                    lines.append(MdLine(Block(.code), source[i]))
                    i += 1
                }
                if lines.count == start { lines.append(MdLine(Block(.code))) }
                i += 1
                continue
            }
            if let header = parseTableRow(line), i + 1 < source.count, isTableSeparator(source[i + 1]) {
                var rows = [header]
                i += 2
                while i < source.count, let row = parseTableRow(source[i]) {
                    rows.append((0..<header.count).map { $0 < row.count ? row[$0] : "" })
                    i += 1
                }
                lines.append(MdLine(Block(.table), table: MdTable(rows: rows)))
                continue
            }
            if let picture = parseImage(line) {
                lines.append(MdLine(Block(.image), image: picture))
                i += 1
                continue
            }
            if let attached = parseFile(line) {
                lines.append(MdLine(Block(.file), file: attached))
                i += 1
                continue
            }
            let prefix = detectBlockPrefix(line)
            let (text, styles) = parseInline(dropUnits(line, prefix?.1 ?? 0))
            lines.append(MdLine(prefix?.0 ?? .paragraph, text, styles: styles))
            i += 1
        }
        return lines
    }

    public static func toMarkdown(_ lines: [MdLine]) -> String {
        var numbers = ListNumbers()
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let block = line.block
            let number = numbers.next(block)
            let lead = block.isListItem ? String(repeating: indent, count: block.depth) : ""
            let body: String
            switch block.type {
            case .code:
                // A run of code lines shares one pair of fences.
                let open = i == 0 || lines[i - 1].block.type != .code ? "```\n" : ""
                let close = i == lines.count - 1 || lines[i + 1].block.type != .code ? "\n```" : ""
                body = open + line.text + close
            case .table: body = tableToMarkdown(line.table ?? MdTable(rows: [[""]]))
            case .image: body = line.image.map(imageToMarkdown) ?? ""
            case .file: body = line.file.map(fileToMarkdown) ?? ""
            case .paragraph: body = inlineToMarkdown(line.text, line.styles)
            case .bullet: body = "- " + inlineToMarkdown(line.text, line.styles)
            case .numbered: body = "\(number). " + inlineToMarkdown(line.text, line.styles)
            case .checkbox: body = (block.checked ? "- [x] " : "- [ ] ") + inlineToMarkdown(line.text, line.styles)
            case .quote: body = "> " + inlineToMarkdown(line.text, line.styles)
            case .heading: body = String(repeating: "#", count: max(1, block.level)) + " " + inlineToMarkdown(line.text, line.styles)
            }
            out.append(lead + body)
        }
        return out.joined(separator: "\n")
    }

    private static func tableToMarkdown(_ table: MdTable) -> String {
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let columns = max(table.columns, 1)
        let rows = (table.rows.isEmpty ? [[]] : table.rows).map { r in (0..<columns).map { $0 < r.count ? r[$0] : "" } }
        return ([row(rows[0]), row(Array(repeating: "---", count: columns))] + rows.dropFirst().map(row)).joined(separator: "\n")
    }

    /// Whether a note has nothing in it.
    public static func isBlank(_ markdown: String) -> Bool {
        parse(markdown).allSatisfy(\.isBlank)
    }

    /// The pictures and files a note refers to, in order, each once.
    public static func assetPaths(_ markdown: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            guard let path = parseImage(line)?.path ?? parseFile(line)?.path, !path.contains("://") else { continue }
            if seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    /// The title of a note: its first line as it reads, without Markdown.
    public static func title(_ markdown: String) -> String {
        NoteSummary.of(markdown).title
    }

    /// Letters and digits only, lowercased: what two versions of a note have to
    /// share to be taken for the same note, whatever either side did to its form.
    public static func contentKey(_ markdown: String) -> String {
        let kept = markdown.components(separatedBy: "\n").filter { parseImage($0) == nil && parseFile($0) == nil }
        return plain(kept.joined(separator: " "))
    }

    public static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
