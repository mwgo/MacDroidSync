import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lays out a note and draws what is not text: bullets, numbers and the round
/// boxes of a checklist in the room left of a list item, the bar of a quote,
/// the panel behind code.
public final class NoteLayoutManager: NSLayoutManager {
    public var style: EditorStyle
    /// The block of the empty last line, which has no character to carry it.
    public var trailingBlock: Block = .paragraph

    private var numbers: [Int: Int] = [:]
    private var numbersValid = false

    public init(style: EditorStyle) {
        self.style = style
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("not coded")
    }

    public override func processEditing(for textStorage: NSTextStorage, edited editMask: TextEditActions, range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        numbersValid = false
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    /// The number of each numbered item, by the location of its paragraph.
    private func number(at location: Int, in text: NSAttributedString) -> Int {
        if !numbersValid {
            numbers = [:]
            var counter = ListNumbers()
            for paragraph in AttributedCodec.paragraphs(text) {
                let block = AttributedCodec.block(of: text, paragraph: paragraph, fallback: trailingBlock)
                let n = counter.next(block)
                if n > 0 { numbers[paragraph.location] = n }
            }
            numbersValid = true
        }
        return numbers[location] ?? 1
    }

    public func invalidateDecorations() {
        numbersValid = false
        guard let storage = textStorage else { return }
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    /// The first line of a paragraph, in the text container's coordinates.
    public func firstLineRect(ofParagraph paragraph: NSRange) -> CGRect? {
        guard let storage = textStorage else { return nil }
        if paragraph.location >= storage.length {
            let extra = extraLineFragmentRect
            return extra.isEmpty ? nil : extra
        }
        let glyph = glyphIndexForCharacter(at: paragraph.location)
        return lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Where the bullet, number or box of a list item is drawn, in the text container's coordinates.
    public func markerRect(ofParagraph paragraph: NSRange, block: Block) -> CGRect? {
        guard block.isListItem, let line = firstLineRect(ofParagraph: paragraph) else { return nil }
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        let x = line.minX + padding + CGFloat(block.depth) * style.listIndent
        return CGRect(x: x, y: line.minY, width: style.markerWidth, height: firstLineHeight(paragraph, line: line))
    }

    private func firstLineHeight(_ paragraph: NSRange, line: CGRect) -> CGFloat {
        let font = paragraph.location < (textStorage?.length ?? 0)
            ? textStorage?.attribute(.font, at: paragraph.location, effectiveRange: nil) as? PlatformFont
            : nil
        let lineHeight = (font ?? PlatformFont.systemFont(ofSize: style.bodySize)).lineHeight
        return min(line.height, lineHeight * 1.12 + 1)
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let paragraphs = AttributedCodec.paragraphs(storage)
        var previous: Block?
        for (index, paragraph) in paragraphs.enumerated() {
            let block = AttributedCodec.block(of: storage, paragraph: paragraph, fallback: trailingBlock)
            defer { previous = block }
            let visible = NSIntersectionRange(paragraph, shown).length > 0
                || (paragraph.location >= shown.location && paragraph.location <= NSMaxRange(shown))
            guard visible else { continue }
            switch block.type {
            case .code:
                let next = index + 1 < paragraphs.count
                    ? AttributedCodec.block(of: storage, paragraph: paragraphs[index + 1], fallback: trailingBlock) : nil
                drawCode(paragraph, container: container, origin: origin, first: previous?.type != .code, last: next?.type != .code)
            case .quote:
                guard let rect = paragraphRect(paragraph) else { continue }
                style.separatorColor.setFill()
                let bar = CGRect(x: origin.x + rect.minX + container.lineFragmentPadding, y: origin.y + rect.minY + 2, width: 3, height: rect.height - 4)
                bezier(roundedRect: bar, radius: 1.5).fill()
            case .bullet, .numbered, .checkbox:
                guard let marker = markerRect(ofParagraph: paragraph, block: block) else { continue }
                drawMarker(block, in: marker.offsetBy(dx: origin.x, dy: origin.y), number: block.type == .numbered ? number(at: paragraph.location, in: storage) : 0)
            default:
                break
            }
        }
    }

    /// The whole paragraph, all of its lines, in the text container's coordinates.
    private func paragraphRect(_ paragraph: NSRange) -> CGRect? {
        guard let storage = textStorage else { return nil }
        if paragraph.location >= storage.length { return firstLineRect(ofParagraph: paragraph) }
        var range = paragraph
        if range.length > 1, (storage.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect: CGRect?
        enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
            rect = rect.map { $0.union(line) } ?? line
        }
        return rect
    }

    private func drawCode(_ paragraph: NSRange, container: NSTextContainer, origin: CGPoint, first: Bool, last: Bool) {
        guard let rect = paragraphRect(paragraph) else { return }
        let padding = container.lineFragmentPadding
        var panel = CGRect(x: origin.x + rect.minX + padding - 4, y: origin.y + rect.minY, width: rect.width - 2 * padding + 8, height: rect.height)
        if first {
            panel.origin.y -= 4
            panel.size.height += 4
        }
        if last { panel.size.height += 4 }
        style.codeBackground.setFill()
        let radius: CGFloat = 6
        if first && last {
            bezier(roundedRect: panel, radius: radius).fill()
        } else {
            // Square where the panel goes on into the next or previous line.
            let path = bezier(roundedRect: panel, radius: radius)
            path.fill()
            if !first { bezier(roundedRect: CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: radius), radius: 0).fill() }
            if !last { bezier(roundedRect: CGRect(x: panel.minX, y: panel.maxY - radius, width: panel.width, height: radius), radius: 0).fill() }
        }
    }

    private func drawMarker(_ block: Block, in rect: CGRect, number: Int) {
        let size = style.bodySize
        let center = CGPoint(x: rect.minX + style.markerWidth * 0.42, y: rect.midY)
        switch block.type {
        case .bullet:
            style.textColor.setFill()
            style.textColor.setStroke()
            let r = size * 0.17
            let dot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            switch block.depth % 3 {
            case 0:
                ovalPath(dot).fill()
            case 1:
                let ring = ovalPath(dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            default:
                bezier(roundedRect: dot.insetBy(dx: 0.5, dy: 0.5), radius: 0).fill()
            }
        case .numbered:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: style.textColor,
            ]
            let text = "\(number)." as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.minX + style.markerWidth - textSize.width - size * 0.35, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        case .checkbox:
            let r = size * 0.55
            let box = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            if block.checked {
                style.accentColor.setFill()
                ovalPath(box).fill()
                let tick = bezier()
                tick.move(to: CGPoint(x: box.minX + r * 0.55, y: box.midY + r * 0.02))
                tick.addLine(to: CGPoint(x: box.minX + r * 0.88, y: box.midY + r * 0.36))
                tick.addLine(to: CGPoint(x: box.maxX - r * 0.5, y: box.midY - r * 0.36))
                tick.lineWidth = max(1.6, size * 0.12)
                PlatformColor.white.setStroke()
                tick.stroke()
            } else {
                let ring = ovalPath(box.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.3
                style.secondaryColor.setStroke()
                ring.stroke()
            }
        default:
            break
        }
    }

    private func ovalPath(_ rect: CGRect) -> PlatformBezier {
        #if os(macOS)
        return NSBezierPath(ovalIn: rect)
        #else
        return UIBezierPath(ovalIn: rect)
        #endif
    }
}
