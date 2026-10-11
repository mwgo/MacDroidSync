import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A note's Markdown as text the editor holds, and back. The meaning rides on
/// attributes of its own - the block of each paragraph, bold, italic,
/// underline, code - from which `Restyler` makes the fonts and spacing; the
/// Markdown is written from those attributes alone.
public enum AttributedCodec {

    public static func attributed(_ markdown: String, maker: AttachmentMaker) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let lines = Markdown.parse(markdown)
        for (index, line) in lines.enumerated() {
            let block = line.block.encoded
            let start = out.length
            if line.block.isObject {
                let source = Markdown.toMarkdown([line])
                let attachment = maker.attachment(for: line, source: source)
                let object = NSMutableAttributedString(attachment: attachment)
                object.addAttribute(.mdObject, value: source, range: NSRange(location: 0, length: object.length))
                out.append(object)
            } else {
                out.append(NSAttributedString(string: line.text))
                for style in line.styles where style.start < style.end {
                    out.addAttribute(style.kind.key, value: true, range: NSRange(location: start + style.start, length: style.end - style.start))
                }
            }
            if index < lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
            out.addAttribute(.mdBlock, value: block, range: NSRange(location: start, length: out.length - start))
        }
        Restyler.restyle(out, style: maker.style)
        return out
    }

    /// The paragraphs of the text, each with its newline when it has one.
    public static func paragraphs(_ text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        if string.length == 0 || string.hasSuffix("\n") {
            ranges.append(NSRange(location: string.length, length: 0))
        }
        return ranges
    }

    /// The block of the paragraph at `range`; `fallback` for the empty one at the very end.
    public static func block(of text: NSAttributedString, paragraph range: NSRange, fallback: Block = .paragraph) -> Block {
        guard range.length > 0 || range.location < text.length else { return fallback }
        let at = min(range.location, text.length - 1)
        guard at >= 0, let value = text.attribute(.mdBlock, at: at, effectiveRange: nil) as? String else { return .paragraph }
        return Block(encoded: value)
    }

    public static func markdown(_ text: NSAttributedString, trailing: Block = .paragraph) -> String {
        let string = text.string as NSString
        var lines: [MdLine] = []
        for range in paragraphs(text) {
            let block = block(of: text, paragraph: range, fallback: trailing)
            var body = range
            if body.length > 0, string.character(at: NSMaxRange(body) - 1) == 0x0A { body.length -= 1 }
            if let object = objectSource(text, in: body) {
                lines.append(contentsOf: Markdown.parse(object))
                continue
            }
            let raw = string.substring(with: body)
            var styles: [InlineStyle] = []
            for kind in InlineKind.all {
                text.enumerateAttribute(kind.key, in: body) { value, run, _ in
                    guard (value as? Bool) == true else { return }
                    styles.append(InlineStyle(kind, run.location - body.location, NSMaxRange(run) - body.location))
                }
            }
            // An object character that lost its object, as a paste may leave, is no text.
            let clean = raw.replacingOccurrences(of: String(objectCharacter), with: "")
            if clean != raw { styles = [] }
            var line = MdLine(block.isObject ? .paragraph : block, clean, styles: block.type == .code ? [] : styles)
            if line.block.type == .checkbox, line.block.depth > Block.maxDepth { line.block.depth = Block.maxDepth }
            lines.append(line)
        }
        return Markdown.toMarkdown(lines)
    }

    private static func objectSource(_ text: NSAttributedString, in range: NSRange) -> String? {
        guard range.length > 0 else { return nil }
        var found: String?
        text.enumerateAttribute(.mdObject, in: range) { value, _, stop in
            if let source = value as? String {
                found = source
                stop.pointee = true
            }
        }
        return found
    }
}

/// Fonts, colours and spacing from the attributes that say what the text is.
public enum Restyler {

    /// Every paragraph touching `range`, or the whole text.
    public static func restyle(_ text: NSMutableAttributedString, in range: NSRange? = nil, style: EditorStyle) {
        let all = AttributedCodec.paragraphs(text)
        let wanted = range ?? NSRange(location: 0, length: text.length)
        var previous: Block?
        text.beginEditing()
        for (index, paragraph) in all.enumerated() {
            let block = AttributedCodec.block(of: text, paragraph: paragraph)
            defer { previous = block }
            guard paragraph.length > 0 else { continue }
            let touches = NSIntersectionRange(paragraph, wanted).length > 0
                || (wanted.length == 0 && wanted.location >= paragraph.location && wanted.location <= NSMaxRange(paragraph))
            guard touches || range == nil else { continue }
            let isTitle = index == 0 && block.type == .heading
            text.addAttribute(.paragraphStyle, value: style.paragraphStyle(for: block, isTitle: isTitle, previous: previous), range: paragraph)
            restyleRuns(text, paragraph: paragraph, block: block, isTitle: isTitle, style: style)
        }
        text.endEditing()
    }

    static func restyleRuns(_ text: NSMutableAttributedString, paragraph: NSRange, block: Block, isTitle: Bool, style: EditorStyle) {
        let done = block.type == .checkbox && block.checked
        text.enumerateAttributes(in: paragraph) { attributes, run, _ in
            let bold = (attributes[.mdBold] as? Bool) == true
            let italic = (attributes[.mdItalic] as? Bool) == true
            let underline = (attributes[.mdUnderline] as? Bool) == true
            let code = (attributes[.mdCode] as? Bool) == true
            let inlineCode = code && block.type != .code
            var set: [NSAttributedString.Key: Any] = [
                .font: style.font(for: block, isTitle: isTitle, bold: bold, italic: italic, code: code),
                .foregroundColor: Restyler.color(block: block, isTitle: isTitle, done: done, inlineCode: inlineCode, style: style),
            ]
            set[.underlineStyle] = underline ? NSUnderlineStyle.single.rawValue : nil
            set[.underlineColor] = underline ? style.accentColor : nil
            set[.strikethroughStyle] = done ? NSUnderlineStyle.single.rawValue : nil
            set[.backgroundColor] = inlineCode ? style.inlineCodeBackground : nil
            set[.kern] = style.isCaps(block, isTitle: isTitle) ? style.size(of: block, isTitle: isTitle) * 0.06 : nil
            for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .strikethroughStyle, .backgroundColor, .kern] where set[key] == nil {
                text.removeAttribute(key, range: run)
            }
            text.addAttributes(set.compactMapValues { $0 }, range: run)
        }
    }

    static func color(block: Block, isTitle: Bool, done: Bool, inlineCode: Bool, style: EditorStyle) -> PlatformColor {
        if done { return style.secondaryColor }
        if block.type == .heading { return style.headingColor(block, isTitle: isTitle) }
        return inlineCode ? style.inlineCodeColor : style.textColor
    }

    /// What newly typed text gets in a paragraph of `block`.
    public static func typingAttributes(block: Block, isTitle: Bool, inline: Set<InlineKind>, style: EditorStyle, previous: Block?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .mdBlock: block.encoded,
            .font: style.font(for: block, isTitle: isTitle, bold: inline.contains(.bold), italic: inline.contains(.italic), code: inline.contains(.code)),
            .foregroundColor: color(block: block, isTitle: isTitle, done: block.type == .checkbox && block.checked,
                                    inlineCode: inline.contains(.code) && block.type != .code, style: style),
            .paragraphStyle: style.paragraphStyle(for: block, isTitle: isTitle, previous: previous),
        ]
        for kind in inline where block.type != .code { attributes[kind.key] = true }
        if inline.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = style.accentColor
        }
        if inline.contains(.code) && block.type != .code { attributes[.backgroundColor] = style.inlineCodeBackground }
        if style.isCaps(block, isTitle: isTitle) { attributes[.kern] = style.size(of: block, isTitle: isTitle) * 0.06 }
        return attributes
    }
}
