import Foundation

/// The Markdown of the phone's notes and the HTML of Notes on the Mac, each
/// turned into the other.
///
/// Notes keeps its own idea of a note and rewrites what it is given: a heading
/// comes back as bold text of a size, monospace as Courier, a quote as a plain
/// line, and a picture set into the body stays an attachment that the body no
/// longer shows. Both directions are therefore written against what Notes
/// actually reads and writes, not against HTML in general. What Notes cannot
/// hold travels as a mark in the text instead: ☐ and ☑ for the tasks, │ for a
/// quote, so that they survive the round trip.
public enum NotesMarkup {

    /// One line of a note, the subset of the phone's Markdown this needs.
    public enum Line: Equatable {
        case paragraph(String)
        case heading(Int, String)
        /// `depth` is how far a list item is nested, 0 for the outermost.
        case bullet(String, depth: Int)
        case numbered(String, depth: Int)
        case checkbox(Bool, String, depth: Int)
        case quote(String)
        case code(String)
        case table([[String]])
        case image(path: String, alt: String)
        case file(path: String, name: String)
    }

    static let unchecked = "☐ "
    static let checked = "☑ "
    static let quoteMark = "│ "

    /// Where a picture goes in Markdown made from a note on the Mac: the index
    /// into `Incoming.images`, replaced by a path once the picture has one.
    public static func imagePlaceholder(_ index: Int) -> String { "@image:\(index)" }

    /// Where an attachment Notes does not show in the body stood.
    public static let attachmentPlaceholder = "@attachment"

    // MARK: - Reading Markdown

    /// What each level of a nested list is indented by, as on the phone.
    static let indent = "    "

    /// The deepest a list nests, the outermost level not counted; as on the phone.
    static let maxDepth = 5

    public static func lines(_ markdown: String) -> [Line] {
        let source = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var lines: [Line] = []
        // The indents of the list items open above, outermost first.
        var indents: [Int] = []
        var i = 0
        while i < source.count {
            let line = source[i]
            let lead = line.prefix(while: { $0 == " " || $0 == "\t" })
            let columns = lead.reduce(0) { $0 + ($1 == "\t" ? indent.count : 1) }
            let body = String(line.dropFirst(lead.count))
            if listItem(body, depth: 0) != nil {
                // Deeper than the item above when indented further, back at the level it lines up with otherwise.
                while let last = indents.last, last > columns { indents.removeLast() }
                if indents.last.map({ $0 < columns }) ?? true { indents.append(columns) }
                lines.append(listItem(body, depth: min(indents.count - 1, maxDepth))!)
                i += 1
                continue
            }
            indents.removeAll()
            if isFence(line) {
                i += 1
                var any = false
                while i < source.count, !isFence(source[i]) {
                    lines.append(.code(source[i]))
                    i += 1
                    any = true
                }
                if !any { lines.append(.code("")) }
                i += 1
                continue
            }
            if let header = tableRow(line), i + 1 < source.count, isTableSeparator(source[i + 1]) {
                var rows = [header]
                i += 2
                while i < source.count, let row = tableRow(source[i]) {
                    rows.append((0..<header.count).map { $0 < row.count ? row[$0] : "" })
                    i += 1
                }
                lines.append(.table(rows))
                continue
            }
            lines.append(parseLine(line))
            i += 1
        }
        return lines
    }

    static func parseLine(_ line: String) -> Line {
        if let image = imageLine(line) { return .image(path: image.path, alt: image.alt) }
        if let file = fileLine(line) { return .file(path: file.path, name: file.name) }
        if let match = line.firstMatch(of: headingPrefix) {
            return .heading(match.output[1].substring.map { $0.count } ?? 1, String(line[match.range.upperBound...]))
        }
        if let item = listItem(line, depth: 0) { return item }
        if let match = line.firstMatch(of: quotePrefix) { return .quote(String(line[match.range.upperBound...])) }
        return .paragraph(line)
    }

    static func listItem(_ line: String, depth: Int) -> Line? {
        if let match = line.firstMatch(of: checkboxPrefix) {
            let mark = match.output[1].substring.map(String.init) ?? ""
            return .checkbox(!mark.trimmingCharacters(in: .whitespaces).isEmpty, String(line[match.range.upperBound...]), depth: depth)
        }
        if let match = line.firstMatch(of: bulletPrefix) { return .bullet(String(line[match.range.upperBound...]), depth: depth) }
        if let match = line.firstMatch(of: numberedPrefix) { return .numbered(String(line[match.range.upperBound...]), depth: depth) }
        return nil
    }

    private static let headingPrefix = try! Regex("^(#{1,6}) ")
    private static let checkboxPrefix = try! Regex("^(?:[-*] )?\\[([ xX]?)\\] ")
    private static let bulletPrefix = try! Regex("^[-*] ")
    private static let numberedPrefix = try! Regex("^\\d+\\. ")
    private static let quotePrefix = try! Regex("^>( |$)")
    private static let imagePattern = try! Regex("^\\s*!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)\\s*$")
    private static let filePattern = try! Regex("^\\s*\\[([^\\]]*)\\]\\((files/[^)\\s]+)\\)\\s*$")
    private static let separatorCell = try! Regex("^:?-+:?$")

    public static func imageLine(_ line: String) -> (path: String, alt: String)? {
        guard let match = line.wholeMatch(of: imagePattern),
              let alt = match.output[1].substring, let path = match.output[2].substring else { return nil }
        return (String(path), String(alt))
    }

    static func fileLine(_ line: String) -> (path: String, name: String)? {
        guard let match = line.wholeMatch(of: filePattern),
              let name = match.output[1].substring, let path = match.output[2].substring else { return nil }
        return (String(path), String(name))
    }

    static func isFence(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```")
    }

    static func tableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        return trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        tableRow(line)?.allSatisfy { $0.wholeMatch(of: separatorCell) != nil } == true
    }

    // MARK: - Markdown to Notes

    /// A note ready for Notes: its body, and the pictures and files it shows, in
    /// order. Notes keeps a picture set into the body as data as a broken "File"
    /// attachment, and puts one made by script at the end of the note; what it
    /// does take in place is `<img src="file://…">` for a file it was given by
    /// an Apple event just before, a picture or any other file. So each one
    /// stands in the body as such a reference to its local copy.
    public struct Outgoing: Equatable {
        public var html: String
        public var files: [(path: String, name: String)]

        public static func == (a: Outgoing, b: Outgoing) -> Bool {
            a.html == b.html && a.files.map(\.path) == b.files.map(\.path) && a.files.map(\.name) == b.files.map(\.name)
        }
    }

    /// The body Notes is given for `markdown`. `local` is the copy on this Mac
    /// of a picture or file by its path on the phone; one without is left out.
    public static func html(fromMarkdown markdown: String, local: (String) -> URL? = { _ in nil }) -> Outgoing {
        var html = ""
        var files: [(String, String)] = []
        // The lists open, outermost first. A nested list stands inside its
        // parent list next to the items, as Notes writes it.
        var open: [String] = []
        func closeList() {
            while let list = open.popLast() { html += "</\(list)>" }
        }
        func listItem(_ kind: String, _ depth: Int, _ content: String) {
            while open.count > depth + 1, let list = open.popLast() { html += "</\(list)>" }
            if open.count == depth + 1, open.last != kind, let list = open.popLast() { html += "</\(list)>" }
            while open.count < depth + 1 {
                html += "<\(kind)>"
                open.append(kind)
            }
            html += "<li>\(content)</li>"
        }
        for (index, line) in lines(markdown).enumerated() {
            switch line {
            case .bullet(let text, let depth): listItem("ul", depth, inlineHTML(text))
            case .numbered(let text, let depth): listItem("ol", depth, inlineHTML(text))
            // A task in a list keeps its place there; one on its own is a line, as Notes shows tasks.
            case .checkbox(let done, let text, let depth) where depth > 0:
                listItem("ul", depth, escape(done ? checked : unchecked) + inlineHTML(text))
            default:
                closeList()
                switch line {
                case .heading(let level, let text):
                    let tag = index == 0 || level == 1 ? "h1" : level == 2 ? "h2" : "h3"
                    html += "<div><\(tag)>\(inlineHTML(text))</\(tag)></div>"
                case .paragraph(let text):
                    if index == 0 {
                        html += "<div><h1>\(inlineHTML(text))</h1></div>"
                    } else {
                        html += text.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(inlineHTML(text))</div>"
                    }
                case .checkbox(let done, let text, _):
                    html += "<div>\(escape(done ? checked : unchecked))\(inlineHTML(text))</div>"
                case .quote(let text):
                    html += "<div>\(escape(quoteMark))\(inlineHTML(text))</div>"
                case .code(let text):
                    html += text.isEmpty ? "<div><tt><br></tt></div>" : "<div><tt>\(escape(text))</tt></div>"
                case .table(let rows):
                    html += "<div><table><tbody>"
                    for row in rows {
                        html += "<tr>" + row.map { "<td><div>\(inlineHTML($0))</div></td>" }.joined() + "</tr>"
                    }
                    html += "</tbody></table></div>"
                case .image(let path, _):
                    files.append((path, (path as NSString).lastPathComponent))
                    if let url = local(path) { html += "<div><img src=\"\(escape(url.absoluteString))\"></div>" }
                case .file(let path, let name):
                    files.append((path, name))
                    if let url = local(path) { html += "<div><img src=\"\(escape(url.absoluteString))\"></div>" }
                case .bullet, .numbered:
                    break
                }
            }
        }
        closeList()
        return Outgoing(html: html, files: files)
    }

    /// The inline Markdown of one line as HTML: `**` bold, `*`/`_` italic,
    /// `__` underline, backticks monospace, with the same pairing rules as the
    /// phone's editor.
    static func inlineHTML(_ source: String) -> String {
        render(Array(source), html: true)
    }

    /// The text of one line of inline Markdown without its delimiters.
    public static func inlineText(_ source: String) -> String {
        render(Array(source), html: false)
    }

    private static func render(_ s: [Character], html: Bool) -> String {
        var out = ""
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "`", let close = index(of: "`", in: s, from: i + 1), close > i + 1 {
                let inner = String(s[(i + 1)..<close])
                out += html ? "<tt>\(escape(inner))</tt>" : inner
                i = close + 1
                continue
            }
            if c == "*" || c == "_" {
                let delimiter = i + 1 < s.count && s[i + 1] == c ? 2 : 1
                if let close = findClose(s, open: i, c: c, delimiter: delimiter) {
                    let inner = render(Array(s[(i + delimiter)..<close]), html: html)
                    if html {
                        let tag = delimiter == 1 ? "i" : c == "*" ? "b" : "u"
                        out += "<\(tag)>\(inner)</\(tag)>"
                    } else {
                        out += inner
                    }
                    i = close + delimiter
                    continue
                }
            }
            out += html ? escape(String(c)) : String(c)
            i += 1
        }
        return out
    }

    private static func index(of c: Character, in s: [Character], from: Int) -> Int? {
        guard from < s.count else { return nil }
        return s[from...].firstIndex(of: c)
    }

    private static func findClose(_ s: [Character], open: Int, c: Character, delimiter: Int) -> Int? {
        let from = open + delimiter
        guard from < s.count, !s[from].isWhitespace else { return nil }
        if c == "_", open > 0, s[open - 1].isLetter || s[open - 1].isNumber { return nil }
        var j = from + 1
        while j < s.count {
            let ch = s[j]
            if ch == "`", let end = index(of: "`", in: s, from: j + 1), end > j + 1 {
                j = end + 1
                continue
            }
            if ch == c {
                var run = 1
                while j + run < s.count, s[j + run] == c { run += 1 }
                if run == delimiter, !s[j - 1].isWhitespace { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - Notes to Markdown

    /// A note from the Mac in the phone's Markdown. Pictures stand as
    /// `![](@image:N)`, indexing `images`, and the places of attachments Notes
    /// does not show in the body as `@attachment` lines.
    public struct Incoming: Equatable {
        public var markdown: String
        public var images: [(data: Data, mime: String)]

        public static func == (a: Incoming, b: Incoming) -> Bool {
            a.markdown == b.markdown && a.images.map(\.data) == b.images.map(\.data)
        }
    }

    /// The Markdown of a note whose body is `html` and whose name is `title`.
    /// The first line is always the title, as on the phone.
    public static func markdown(fromHTML html: String, title: String) -> Incoming {
        let reader = NotesReader()
        reader.bodySize = NotesReader.bodySize(of: html)
        reader.read(HTMLTree.parse(html))
        var lines = reader.lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = lines.first, plain(first) == plain(name) || name.isEmpty {
            lines[0] = "# " + (name.isEmpty ? plainTitle(first) : name)
        } else {
            lines.insert("# " + name, at: 0)
        }
        return Incoming(markdown: groupCode(lines).joined(separator: "\n"), images: reader.images)
    }

    /// Code lines come out one by one and go back into one fenced block.
    private static func groupCode(_ lines: [String]) -> [String] {
        var out: [String] = []
        var inCode = false
        for line in lines {
            if line.hasPrefix(NotesReader.codeMark) {
                if !inCode { out.append("```") }
                inCode = true
                out.append(String(line.dropFirst(NotesReader.codeMark.count)))
                continue
            }
            if inCode { out.append("```") }
            inCode = false
            out.append(line)
        }
        if inCode { out.append("```") }
        return out
    }

    private static func plainTitle(_ line: String) -> String {
        let text = line.hasPrefix("# ") ? String(line.dropFirst(2)) : line
        return inlineText(text)
    }

    /// Letters and digits only, lowercased: what two versions of a note have to
    /// share to be taken for the same note, whatever either side did to its form.
    public static func contentKey(_ markdown: String) -> String {
        let kept = markdown.components(separatedBy: "\n").filter { imageLine($0) == nil && fileLine($0) == nil && $0 != attachmentPlaceholder }
        return plain(kept.joined(separator: " "))
    }

    static func plain(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Reading Notes HTML

/// A forgiving reader of the HTML Notes writes: no validation, unknown tags
/// kept as plain containers, and the entities Notes leaves without their
/// semicolon read all the same.
final class HTMLNode {
    let tag: String
    var text = ""
    var attributes: [String: String] = [:]
    var children: [HTMLNode] = []

    init(tag: String) {
        self.tag = tag
    }

    var isText: Bool { tag == "#text" }

    func descendants(_ tag: String) -> [HTMLNode] {
        children.flatMap { ($0.tag == tag ? [$0] : []) + $0.descendants(tag) }
    }
}

enum HTMLTree {
    private static let voidTags: Set<String> = ["br", "img", "hr", "meta", "link", "input", "wbr"]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(tag: "#root")
        var stack = [root]
        let s = Array(html.unicodeScalars)
        var i = 0
        var text = String.UnicodeScalarView()

        func flushText() {
            guard !text.isEmpty else { return }
            let node = HTMLNode(tag: "#text")
            node.text = decodeEntities(String(text))
            stack.last!.children.append(node)
            text = String.UnicodeScalarView()
        }

        while i < s.count {
            let c = s[i]
            guard c == "<" else {
                text.append(c)
                i += 1
                continue
            }
            if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                flushText()
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = j + 3
                continue
            }
            guard i + 1 < s.count, s[i + 1] == "/" || s[i + 1].properties.isAlphabetic || s[i + 1] == "!" else {
                text.append(c)
                i += 1
                continue
            }
            flushText()
            var j = i + 1
            while j < s.count, s[j] != ">" {
                if s[j] == "\"" || s[j] == "'" {
                    let quote = s[j]
                    j += 1
                    while j < s.count, s[j] != quote { j += 1 }
                }
                j += 1
            }
            let inside = String(String.UnicodeScalarView(s[(i + 1)..<min(j, s.count)]))
            i = j + 1
            if inside.hasPrefix("!") { continue }
            if inside.hasPrefix("/") {
                let name = inside.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if let at = stack.lastIndex(where: { $0.tag == name }), at > 0 {
                    stack.removeSubrange(at...)
                }
                continue
            }
            let selfClosing = inside.hasSuffix("/")
            let body = selfClosing ? String(inside.dropLast()) : inside
            let name = String(body.prefix { !$0.isWhitespace }).lowercased()
            let node = HTMLNode(tag: name)
            node.attributes = attributes(String(body.dropFirst(name.count)))
            stack.last!.children.append(node)
            if !selfClosing, !voidTags.contains(name) { stack.append(node) }
        }
        flushText()
        return root
    }

    private static func attributes(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        let s = Array(source)
        var i = 0
        while i < s.count {
            while i < s.count, s[i].isWhitespace { i += 1 }
            var name = ""
            while i < s.count, !s[i].isWhitespace, s[i] != "=" {
                name.append(s[i])
                i += 1
            }
            guard !name.isEmpty else {
                i += 1
                continue
            }
            while i < s.count, s[i].isWhitespace { i += 1 }
            var value = ""
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, s[i].isWhitespace { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i += 1
                    while i < s.count, s[i] != quote {
                        value.append(s[i])
                        i += 1
                    }
                    i += 1
                } else {
                    while i < s.count, !s[i].isWhitespace {
                        value.append(s[i])
                        i += 1
                    }
                }
            }
            result[name.lowercased()] = decodeEntities(value)
        }
        return result
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        let s = Array(text)
        var i = 0
        while i < s.count {
            guard s[i] == "&" else {
                out.append(s[i])
                i += 1
                continue
            }
            var j = i + 1
            var name = ""
            while j < s.count, j - i < 10, s[j] != ";", s[j] != "&", !s[j].isWhitespace {
                name.append(s[j])
                j += 1
            }
            let semicolon = j < s.count && s[j] == ";"
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    i = semicolon ? j + 1 : j
                    continue
                }
            } else if let known = named[name] {
                out += known
                i = semicolon ? j + 1 : j
                continue
            } else if let known = named.first(where: { name.hasPrefix($0.key) }) {
                // `&quotfajnej` - Notes sometimes drops the semicolon.
                out += known.value
                i += 1 + known.key.count
                continue
            }
            out.append("&")
            i += 1
        }
        return out
    }
}

/// Walks a Notes body and writes it out line by line in the phone's Markdown.
final class NotesReader {
    /// Marks a code line until the lines are grouped into fenced blocks.
    static let codeMark = "\u{0}code\u{0}"

    private(set) var lines: [String] = []
    private(set) var images: [(data: Data, mime: String)] = []

    private struct Style: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var code = false
        var heading = 0
    }

    private struct Run {
        var text: String
        var style: Style
    }

    private var runs: [Run] = []
    /// Where the lines of the block being read start: a break makes an empty
    /// line only at its start, elsewhere it just ends the line before it.
    private var blockStart = 0

    func read(_ root: HTMLNode) {
        for node in root.children { block(node) }
        flush()
    }

    private func block(_ node: HTMLNode) {
        switch node.tag {
        case "#text":
            if !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inline(node, Style())
                flush()
            }
        case "ul", "ol":
            list(node, ordered: node.tag == "ol")
        case "table":
            table(node)
        case "object", "blockquote", "body", "html":
            for child in node.children { block(child) }
        default:
            // An empty line holding two breaks is where Notes keeps an
            // attachment it does not draw into the body.
            let breaks = node.children.filter { !($0.isText && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            if breaks.count == 2, breaks.allSatisfy({ $0.tag == "br" }) {
                flush()
                lines.append(NotesMarkup.attachmentPlaceholder)
                return
            }
            let before = lines.count
            blockStart = before
            inline(node, Style())
            flush(keepEmpty: lines.count == before)
        }
    }

    private func inline(_ node: HTMLNode, _ outer: Style) {
        if node.isText {
            let text = node.text.replacingOccurrences(of: "\n", with: "")
            if !text.isEmpty { runs.append(Run(text: text, style: outer)) }
            return
        }
        var style = outer
        switch node.tag {
        case "br":
            flush(keepEmpty: lines.count == blockStart)
            blockStart = -1
            return
        case "img":
            flush()
            if let source = node.attributes["src"], let picture = Self.dataURL(source) {
                images.append(picture)
                lines.append("![](\(NotesMarkup.imagePlaceholder(images.count - 1)))")
            }
            return
        case "table":
            flush()
            table(node)
            return
        case "ul", "ol":
            flush()
            list(node, ordered: node.tag == "ol")
            return
        case "b", "strong": style.bold = true
        case "i", "em": style.italic = true
        case "u": style.underline = true
        case "tt", "code", "pre": style.code = true
        case "h1": style.heading = 1
        case "h2": style.heading = 2
        case "h3", "h4", "h5", "h6": style.heading = 3
        case "font":
            let face = (node.attributes["face"] ?? "").lowercased()
            if ["courier", "menlo", "monaco", "mono"].contains(where: face.contains) { style.code = true }
            if face.contains("bold"), style.heading == 0 { style.heading = 3 }
        case "span":
            if let size = Self.fontSize(node.attributes["style"]), style.heading != 0 || outer.bold {
                let scale = size / bodySize
                style.heading = scale >= 1.6 ? 1 : scale >= 1.2 ? 2 : style.heading
            }
        default:
            break
        }
        for child in node.children { inline(child, style) }
    }

    /// A list nested in another, inside an item or next to the items, is one level deeper.
    private func list(_ node: HTMLNode, ordered: Bool, depth: Int = 0) {
        let indent = String(repeating: NotesMarkup.indent, count: min(depth, NotesMarkup.maxDepth))
        for item in node.children {
            switch item.tag {
            case "li":
                var nested: [HTMLNode] = []
                for child in item.children {
                    if child.tag == "ul" || child.tag == "ol" { nested.append(child) } else { inline(child, Style()) }
                }
                let text = render().trimmingCharacters(in: .whitespaces)
                runs = []
                if text.hasPrefix(NotesMarkup.unchecked) || text.hasPrefix(NotesMarkup.checked) {
                    lines.append(indent + Self.prefixed(text))
                } else {
                    lines.append(indent + (ordered ? "1. " : "- ") + text)
                }
                for list in nested { self.list(list, ordered: list.tag == "ol", depth: depth + 1) }
            case "ul", "ol":
                list(item, ordered: item.tag == "ol", depth: depth + 1)
            default:
                break
            }
        }
    }

    private func table(_ node: HTMLNode) {
        let rows = node.descendants("tr").map { row in
            row.children.filter { $0.tag == "td" || $0.tag == "th" }.map { cell -> String in
                let reader = NotesReader()
                for child in cell.children { reader.block(child) }
                reader.flush()
                return reader.lines
                    .filter { !$0.isEmpty && !$0.hasPrefix("![") && $0 != NotesMarkup.attachmentPlaceholder }
                    .joined(separator: " ")
                    .replacingOccurrences(of: "|", with: "¦")
            }
        }.filter { !$0.isEmpty }
        guard let first = rows.first else { return }
        let columns = rows.map(\.count).max() ?? first.count
        func row(_ cells: [String]) -> String {
            "| " + (0..<columns).map { $0 < cells.count ? cells[$0] : "" }.joined(separator: " | ") + " |"
        }
        lines.append(row(first))
        lines.append(row(Array(repeating: "---", count: columns)))
        for other in rows.dropFirst() { lines.append(row(other)) }
    }

    /// Ends the line being read. A line that is all heading text becomes a
    /// heading, all monospace a code line; the marks Notes cannot keep as
    /// formatting become blocks again.
    private func flush(keepEmpty: Bool = false) {
        defer { runs = [] }
        let visible = runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if visible.isEmpty {
            if keepEmpty { lines.append("") }
            return
        }
        if visible.allSatisfy({ $0.style.code }) {
            lines.append(Self.codeMark + runs.map(\.text).joined())
            return
        }
        let levels = visible.map(\.style.heading)
        if levels.allSatisfy({ $0 > 0 }), let level = levels.min() {
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            lines.append(String(repeating: "#", count: level) + " " + text)
            return
        }
        lines.append(Self.prefixed(render()))
    }

    private static func prefixed(_ text: String) -> String {
        if text.hasPrefix(NotesMarkup.unchecked) { return "- [ ] " + text.dropFirst(NotesMarkup.unchecked.count) }
        if text.hasPrefix(NotesMarkup.checked) { return "- [x] " + text.dropFirst(NotesMarkup.checked.count) }
        if text.hasPrefix(NotesMarkup.quoteMark) { return "> " + text.dropFirst(NotesMarkup.quoteMark.count) }
        return text
    }

    /// The runs of the line as inline Markdown, each style's delimiters around
    /// the words, never around the spaces next to them.
    private func render() -> String {
        var merged: [Run] = []
        for run in runs {
            if var last = merged.last, last.style == run.style {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged.map { run in
            let text = run.text.replacingOccurrences(of: "\u{00A0}", with: " ")
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            var open = ""
            var close = ""
            if run.style.code {
                open = "`"
                close = "`"
            } else {
                if run.style.bold && run.style.heading == 0 {
                    open += "**"
                    close = "**" + close
                }
                if run.style.italic {
                    open += "*"
                    close = "*" + close
                }
                if run.style.underline {
                    open += "__"
                    close = "__" + close
                }
            }
            let lead = String(text.prefix { $0 == " " })
            let trail = String(text.reversed().prefix { $0 == " " })
            return lead + open + core + close + trail
        }.joined()
    }

    /// The size of the note's text: Notes writes every size out, 24, 18 and 13
    /// points by default, 21, 15 and 11 in a note made smaller, so a heading is
    /// told by how much bigger it is. The size most of the text has; 13 when none is given.
    var bodySize = 13.0

    static func bodySize(of html: String) -> Double {
        var counts: [Double: Int] = [:]
        var rest = html[...]
        while let range = rest.range(of: "font-size:") {
            rest = rest[range.upperBound...]
            if let size = Double(rest.drop(while: { $0 == " " }).prefix { $0.isNumber || $0 == "." }), size > 0 {
                counts[size, default: 0] += 1
            }
        }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 13
    }

    private static func fontSize(_ style: String?) -> Double? {
        guard let style, let range = style.range(of: "font-size:") else { return nil }
        let rest = style[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(rest.prefix { $0.isNumber || $0 == "." })
    }

    static func dataURL(_ source: String) -> (data: Data, mime: String)? {
        guard source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[source.index(source.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(";base64".count))
        guard let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            return nil
        }
        return (data, mime.isEmpty ? "image/png" : mime)
    }
}
