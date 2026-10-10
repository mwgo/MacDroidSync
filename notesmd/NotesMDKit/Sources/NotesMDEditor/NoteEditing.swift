import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The rules of the editor, apart from any view, as on the phone: Enter goes
/// on with a list and ends it on an empty item, Backspace at the start of a
/// line takes its list or heading away, Markdown typed at the start of a line
/// or around words turns into what it stands for, and the toolbar's commands.
/// The text view hands every change here first, and calls `didChange` after.
public final class NoteEditing {
    public let storage: NSTextStorage
    public var style: EditorStyle
    public var maker: AttachmentMaker
    public weak var layout: NoteLayoutManager?
    /// The block of the empty last line, which no character carries.
    public var trailingBlock: Block = .paragraph {
        didSet { layout?.trailingBlock = trailingBlock }
    }
    /// Styles switched on or off with nothing selected, for what is typed next.
    public var typingInline: Set<InlineKind>?

    public init(storage: NSTextStorage, style: EditorStyle, maker: AttachmentMaker) {
        self.storage = storage
        self.style = style
        self.maker = maker
    }

    // MARK: - The whole note

    public func load(_ markdown: String) {
        let text = AttributedCodec.attributed(markdown, maker: maker)
        storage.beginEditing()
        storage.setAttributedString(text)
        storage.endEditing()
        trailingBlock = .paragraph
        if let last = Markdown.parse(markdown).last, last.isBlank, !last.block.isObject { trailingBlock = last.block }
        typingInline = nil
        layout?.invalidateDecorations()
    }

    public func markdown() -> String {
        AttributedCodec.markdown(storage, trailing: trailingBlock)
    }

    // MARK: - Where things are

    public var paragraphs: [NSRange] { AttributedCodec.paragraphs(storage) }

    public func paragraph(at location: Int) -> NSRange {
        let string = storage.string as NSString
        if location >= string.length {
            if string.length == 0 || string.hasSuffix("\n") { return NSRange(location: string.length, length: 0) }
            return string.paragraphRange(for: NSRange(location: string.length - 1, length: 0))
        }
        return string.paragraphRange(for: NSRange(location: location, length: 0))
    }

    public func block(at location: Int) -> Block {
        block(of: paragraph(at: location))
    }

    public func block(of paragraph: NSRange) -> Block {
        AttributedCodec.block(of: storage, paragraph: paragraph, fallback: trailingBlock)
    }

    /// The paragraph's text without its newline.
    public func body(of paragraph: NSRange) -> NSRange {
        var body = paragraph
        if body.length > 0, (storage.string as NSString).character(at: NSMaxRange(body) - 1) == 0x0A { body.length -= 1 }
        return body
    }

    public func isTitle(_ paragraph: NSRange) -> Bool {
        paragraph.location == 0 && block(of: paragraph).type == .heading
    }

    public func isObject(_ paragraph: NSRange) -> Bool {
        let body = body(of: paragraph)
        guard body.length > 0 else { return false }
        return storage.attribute(.mdObject, at: body.location, effectiveRange: nil) != nil
    }

    /// The paragraphs a selection touches.
    public func paragraphs(in selection: NSRange) -> [NSRange] {
        let first = paragraph(at: selection.location)
        let lastLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        var out = [first]
        var next = NSMaxRange(first)
        while next <= lastLocation, next < storage.length {
            let p = paragraph(at: next)
            out.append(p)
            next = NSMaxRange(p)
        }
        if lastLocation >= storage.length, storage.length > 0, (storage.string as NSString).hasSuffix("\n"), out.last?.location != storage.length {
            out.append(NSRange(location: storage.length, length: 0))
        }
        return out
    }

    /// The inline styles at a place: of the character before it, as typing goes on from there.
    public func inline(at location: Int) -> Set<InlineKind> {
        if let typingInline { return typingInline }
        let p = paragraph(at: location)
        let at = location > p.location ? location - 1 : location
        guard at < storage.length, at >= 0, (storage.string as NSString).character(at: at) != 0x0A else { return [] }
        return Set(InlineKind.all.filter { (storage.attribute($0.key, at: at, effectiveRange: nil) as? Bool) == true })
    }

    public func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let p = paragraph(at: location)
        let index = paragraphs.firstIndex(of: p) ?? 0
        let previous = index > 0 ? block(of: paragraphs[index - 1]) : nil
        var block = block(of: p)
        if block.isObject { block = .paragraph }
        return Restyler.typingAttributes(block: block, isTitle: isTitle(p), inline: inline(at: location), style: style, previous: previous)
    }

    // MARK: - Changes as they are typed

    /// What the editor does instead of a change, or nil to let it happen.
    /// Returns the selection after what it did.
    public func intercept(range: NSRange, replacement: String) -> NSRange? {
        if replacement == "\n" { return enter(range) }
        if replacement.isEmpty, range.length == 1 { return backspace(range) }
        if !replacement.isEmpty, range.length == 0 { return typeIntoObject(range.location, replacement) }
        return nil
    }

    private func enter(_ range: NSRange) -> NSRange? {
        let p = paragraph(at: range.location)
        let block = block(of: p)
        let text = storage.attributedSubstring(from: body(of: p)).string
        if range.length == 0, text.trimmingCharacters(in: .whitespaces).isEmpty, block.type != .paragraph, block.type != .heading {
            // An empty item ends its list, one level at a time.
            var next = block
            if block.isListItem, block.depth > 0 {
                next.depth -= 1
            } else {
                next = .paragraph
            }
            setBlock(next, of: p)
            return NSRange(location: range.location, length: 0)
        }
        replace(range, with: "\n")
        let after = paragraph(at: range.location + 1)
        var next = block
        switch block.type {
        case .heading: next = .paragraph
        case .checkbox: next.checked = false
        case .image, .table, .file: next = .paragraph
        default: break
        }
        setBlock(next, of: after)
        return NSRange(location: range.location + 1, length: 0)
    }

    private func backspace(_ range: NSRange) -> NSRange? {
        let caret = NSMaxRange(range)
        let p = paragraph(at: caret)
        guard p.location == caret, caret > 0 else { return nil }
        let block = block(of: p)
        guard block.type != .paragraph, !block.isObject, !isTitle(p) else { return nil }
        var next = block
        if block.isListItem, block.depth > 0 {
            next.depth -= 1
        } else {
            next = .paragraph
        }
        setBlock(next, of: p)
        return NSRange(location: caret, length: 0)
    }

    /// Text typed next to a picture, table or file goes on a line of its own.
    private func typeIntoObject(_ location: Int, _ text: String) -> NSRange? {
        let p = paragraph(at: location)
        guard isObject(p) else { return nil }
        let body = body(of: p)
        let attributes = Restyler.typingAttributes(block: .paragraph, isTitle: false, inline: [], style: style, previous: nil)
        if location <= body.location {
            storage.replaceCharacters(in: NSRange(location: body.location, length: 0), with: NSAttributedString(string: text + "\n", attributes: attributes))
            return NSRange(location: body.location + (text as NSString).length, length: 0)
        }
        storage.replaceCharacters(in: NSRange(location: NSMaxRange(body), length: 0), with: NSAttributedString(string: "\n" + text, attributes: attributes))
        restyle(around: NSRange(location: NSMaxRange(body), length: (text as NSString).length + 1))
        return NSRange(location: NSMaxRange(body) + 1 + (text as NSString).length, length: 0)
    }

    /// After any change the text view made: every paragraph one block, Markdown typed turned into what it means.
    /// Returns a new selection when the text around the caret changed.
    public func didChange(edited: NSRange, replacement: String, selection: NSRange) -> NSRange? {
        normalize(around: edited)
        // What was typed took the styles chosen for it; what follows goes on from it.
        if !replacement.isEmpty { typingInline = nil }
        var result: NSRange?
        if replacement == " " { result = blockShortcut(at: selection.location) }
        if replacement == "`" { result = fenceShortcut(at: selection.location) ?? inlineShortcut(at: selection.location) }
        if replacement == "*" || replacement == "_" { result = inlineShortcut(at: selection.location) }
        restyle(around: edited)
        layout?.invalidateDecorations()
        return result
    }

    /// Every paragraph near the change carries one block, that of its first
    /// character; text typed into the empty last line takes that line's block.
    private func normalize(around edited: NSRange) {
        let range = NSRange(location: max(0, edited.location - 1), length: edited.length + 2)
        for p in paragraphs(in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) where p.length > 0 {
            let first = storage.attribute(.mdBlock, at: p.location, effectiveRange: nil) as? String
            let value = first ?? trailingBlock.encoded
            var uniform = true
            storage.enumerateAttribute(.mdBlock, in: p) { v, _, stop in
                if (v as? String) != value {
                    uniform = false
                    stop.pointee = true
                }
            }
            if !uniform || first == nil { storage.addAttribute(.mdBlock, value: value, range: p) }
        }
    }

    private func restyle(around range: NSRange) {
        let wide = NSRange(location: max(0, range.location - 1), length: min(range.length + 2, storage.length - max(0, range.location - 1)))
        Restyler.restyle(storage, in: wide, style: style)
    }

    private static let blockPrefixes: [(String, Block)] = [
        ("-", Block(.bullet)), ("*", Block(.bullet)), ("[]", Block(.checkbox)), ("[ ]", Block(.checkbox)),
        ("- []", Block(.checkbox)), ("- [ ]", Block(.checkbox)), ("#", Block(.heading, level: 1)),
        ("##", Block(.heading, level: 2)), ("###", Block(.heading, level: 3)), (">", Block(.quote)),
    ]

    /// `- `, `1. `, `[] `, `# `, `> ` typed at the start of a line.
    private func blockShortcut(at caret: Int) -> NSRange? {
        let p = paragraph(at: caret)
        guard block(of: p).type == .paragraph else { return nil }
        let typed = (storage.string as NSString).substring(with: NSRange(location: p.location, length: caret - p.location))
        guard typed.hasSuffix(" ") else { return nil }
        let prefix = String(typed.dropLast())
        var block = Self.blockPrefixes.first { $0.0 == prefix }?.1
        if block == nil, prefix.hasSuffix("."), Int(prefix.dropLast()) != nil { block = Block(.numbered) }
        guard let block else { return nil }
        let length = (typed as NSString).length
        storage.replaceCharacters(in: NSRange(location: p.location, length: length), with: "")
        setBlock(block, of: paragraph(at: p.location))
        return NSRange(location: p.location, length: 0)
    }

    /// ``` typed at the start of a line makes it code.
    private func fenceShortcut(at caret: Int) -> NSRange? {
        let p = paragraph(at: caret)
        guard block(of: p).type == .paragraph else { return nil }
        let text = (storage.string as NSString).substring(with: body(of: p))
        guard text == "```" else { return nil }
        storage.replaceCharacters(in: body(of: p), with: "")
        setBlock(Block(.code), of: paragraph(at: p.location))
        return NSRange(location: p.location, length: 0)
    }

    /// A closing `*`, `**`, `_`, `__` or backtick: the delimiters go, the style stays.
    private func inlineShortcut(at caret: Int) -> NSRange? {
        let p = paragraph(at: caret)
        let block = block(of: p)
        guard block.type != .code, !isObject(p) else { return nil }
        let body = body(of: p)
        let line = (storage.string as NSString).substring(with: body)
        guard let match = Markdown.findClosedInline(line, cursor: caret - body.location) else { return nil }
        let open = NSRange(location: body.location + match.openStart, length: match.delimiter)
        let close = NSRange(location: body.location + match.closeStart, length: match.delimiter)
        storage.beginEditing()
        storage.replaceCharacters(in: close, with: "")
        storage.replaceCharacters(in: open, with: "")
        let content = NSRange(location: open.location, length: close.location - open.location - match.delimiter)
        storage.addAttribute(match.kind.key, value: true, range: content)
        storage.endEditing()
        typingInline = inline(at: content.location + 1).subtracting([match.kind])
        restyle(around: content)
        return NSRange(location: NSMaxRange(content), length: 0)
    }

    // MARK: - Commands

    /// Bold, italic, underline or code over the selection, or for what is typed next.
    public func toggle(_ kind: InlineKind, selection: NSRange) {
        guard selection.length > 0 else {
            var current = inline(at: selection.location)
            if current.contains(kind) { current.remove(kind) } else { current.insert(kind) }
            typingInline = current
            return
        }
        var all = true
        storage.enumerateAttribute(kind.key, in: selection) { value, _, stop in
            if (value as? Bool) != true {
                all = false
                stop.pointee = true
            }
        }
        storage.beginEditing()
        if all {
            storage.removeAttribute(kind.key, range: selection)
        } else {
            storage.addAttribute(kind.key, value: true, range: selection)
        }
        storage.endEditing()
        restyle(around: selection)
    }

    public func isActive(_ kind: InlineKind, selection: NSRange) -> Bool {
        guard selection.length > 0 else { return inline(at: selection.location).contains(kind) }
        var all = true
        storage.enumerateAttribute(kind.key, in: selection) { value, _, stop in
            if (value as? Bool) != true {
                all = false
                stop.pointee = true
            }
        }
        return all
    }

    /// The selected lines become `type`, or plain text again when they all are already.
    public func toggleBlock(_ type: BlockType, selection: NSRange) {
        let targets = paragraphs(in: selection).filter { !isObject($0) && !isTitle($0) }
        guard !targets.isEmpty else { return }
        let all = targets.allSatisfy { block(of: $0).type == type }
        for p in targets {
            let current = block(of: p)
            var next = Block(type, level: type == .heading ? 2 : 0, depth: current.isListItem && Block.listItems.contains(type) ? current.depth : 0)
            if all { next = .paragraph }
            if type == .code || current.type == .code { clearInline(in: body(of: p)) }
            setBlock(next, of: p)
        }
        layout?.invalidateDecorations()
    }

    /// Heading 1, 2, 3, then plain text again.
    public func cycleHeading(selection: NSRange) {
        for p in paragraphs(in: selection) where !isObject(p) && !isTitle(p) {
            let current = block(of: p)
            let next: Block
            switch (current.type, current.level) {
            case (.heading, 1): next = Block(.heading, level: 2)
            case (.heading, 2): next = Block(.heading, level: 3)
            case (.heading, _): next = .paragraph
            default: next = Block(.heading, level: 1)
            }
            setBlock(next, of: p)
        }
        layout?.invalidateDecorations()
    }

    public func headingLevel(selection: NSRange) -> Int {
        let b = block(at: selection.location)
        return b.type == .heading ? b.level : 0
    }

    /// One level deeper, at most one deeper than the item above and five in all.
    public func indent(selection: NSRange) {
        let all = paragraphs
        for p in paragraphs(in: selection) {
            var current = block(of: p)
            guard current.isListItem else { continue }
            let index = all.firstIndex(of: p) ?? 0
            let above = index > 0 ? block(of: all[index - 1]) : nil
            let limit = above?.isListItem == true ? above!.depth + 1 : 0
            guard current.depth < min(limit, Block.maxDepth) else { continue }
            current.depth += 1
            setBlock(current, of: p)
        }
        layout?.invalidateDecorations()
    }

    public func outdent(selection: NSRange) {
        for p in paragraphs(in: selection) {
            var current = block(of: p)
            guard current.isListItem, current.depth > 0 else { continue }
            current.depth -= 1
            setBlock(current, of: p)
        }
        layout?.invalidateDecorations()
    }

    public func canIndent(selection: NSRange) -> Bool {
        block(at: selection.location).isListItem
    }

    /// Ticks or unticks the box of a checklist item.
    public func toggleCheckbox(paragraph p: NSRange) {
        var current = block(of: p)
        guard current.type == .checkbox else { return }
        current.checked.toggle()
        setBlock(current, of: p)
        layout?.invalidateDecorations()
    }

    /// How many tasks the note has, and how many of them are not done.
    public func tasks() -> (all: Int, open: Int) {
        var all = 0
        var open = 0
        for p in paragraphs {
            let b = block(of: p)
            guard b.type == .checkbox else { continue }
            all += 1
            if !b.checked { open += 1 }
        }
        return (all, open)
    }

    /// A table, picture or file on a line of its own where the selection is.
    /// Returns the selection after it.
    @discardableResult
    public func insertObject(_ source: String, at selection: NSRange) -> NSRange {
        guard let line = Markdown.parse(source).first, line.block.isObject else { return selection }
        replace(selection, with: "")
        var location = selection.location
        let p = paragraph(at: location)
        let body = body(of: p)
        let plain = Restyler.typingAttributes(block: .paragraph, isTitle: false, inline: [], style: style, previous: nil)
        // On a line of its own: the text before it stays above, the text after it goes below.
        if location > body.location || isObject(p) {
            let at = isObject(p) ? NSMaxRange(body) : location
            storage.replaceCharacters(in: NSRange(location: at, length: 0), with: NSAttributedString(string: "\n", attributes: [.mdBlock: block(of: p).encoded]))
            location = at + 1
        }
        let object = NSMutableAttributedString(attachment: maker.attachment(for: line, source: source))
        object.addAttributes([.mdObject: source, .mdBlock: line.block.encoded], range: NSRange(location: 0, length: object.length))
        let rest = paragraph(at: location)
        let restBody = self.body(of: rest)
        let hasTextAfter = restBody.length > 0 && location < NSMaxRange(restBody)
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: object)
        let after = location + object.length
        if hasTextAfter || location >= storage.length - object.length {
            storage.replaceCharacters(in: NSRange(location: after, length: 0), with: NSAttributedString(string: "\n", attributes: plain))
            if !hasTextAfter { trailingBlock = .paragraph }
        }
        if hasTextAfter { storage.addAttribute(.mdBlock, value: block(of: paragraph(at: after + 1)).encoded, range: paragraph(at: after + 1)) }
        normalize(around: NSRange(location: location, length: object.length + 1))
        restyle(around: NSRange(location: location, length: object.length + 1))
        layout?.invalidateDecorations()
        return NSRange(location: min(after + 1, storage.length), length: 0)
    }

    /// Puts a table, picture or file in place of the one at `location`, as edited.
    public func replaceObject(at location: Int, with source: String?) {
        let p = paragraph(at: location)
        guard isObject(p) else { return }
        let body = body(of: p)
        guard let source, let line = Markdown.parse(source).first, line.block.isObject else {
            // Gone: its line with it.
            storage.replaceCharacters(in: p.length > body.length ? p : (p.location > 0 ? NSRange(location: p.location - 1, length: p.length + 1) : p), with: "")
            layout?.invalidateDecorations()
            return
        }
        let object = NSMutableAttributedString(attachment: maker.attachment(for: line, source: source))
        object.addAttributes([.mdObject: source, .mdBlock: line.block.encoded], range: NSRange(location: 0, length: object.length))
        storage.replaceCharacters(in: body, with: object)
        restyle(around: NSRange(location: body.location, length: object.length))
        layout?.invalidateDecorations()
    }

    /// The table, picture or file at a place, if one stands there.
    public func object(at location: Int) -> NoteAttachment? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? NoteAttachment
    }

    // MARK: - Helpers

    private func replace(_ range: NSRange, with text: String) {
        let attributes = typingAttributes(at: range.location)
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
    }

    public func setBlock(_ block: Block, of p: NSRange) {
        if p.length == 0 {
            trailingBlock = block
        } else {
            storage.addAttribute(.mdBlock, value: block.encoded, range: p)
            restyle(around: p)
        }
        layout?.invalidateDecorations()
    }

    private func clearInline(in range: NSRange) {
        for kind in InlineKind.all { storage.removeAttribute(kind.key, range: range) }
    }
}
