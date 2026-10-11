import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a note looks, after Notes: a large bold title, bold headings, the
/// text in the system font, monospace for code.
public struct EditorStyle {
    /// The text container's padding each side, which holds the arrows that fold headings.
    public static let gutter: CGFloat = 18

    public var bodySize: CGFloat
    /// Per nesting level of a list.
    public var listIndent: CGFloat
    /// Room on the left of a list item for its bullet, number or box.
    public var markerWidth: CGFloat

    public init(bodySize: CGFloat? = nil) {
        #if os(macOS)
        self.bodySize = bodySize ?? 14
        #else
        self.bodySize = bodySize ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
        listIndent = (self.bodySize * 1.6).rounded()
        markerWidth = (self.bodySize * 1.7).rounded()
    }

    public func size(of block: Block, isTitle: Bool) -> CGFloat {
        guard block.type == .heading else { return block.type == .code ? bodySize - 1 : bodySize }
        switch isTitle ? 1 : block.level {
        case 1: return (bodySize * 2).rounded()
        case 2: return (bodySize * 1.45).rounded()
        default: return (bodySize * 1.15).rounded()
        }
    }

    public func font(for block: Block, isTitle: Bool, bold: Bool, italic: Bool, code: Bool) -> PlatformFont {
        let size = size(of: block, isTitle: isTitle)
        if block.type == .code || code {
            let weight: PlatformFont.Weight = bold ? .bold : .regular
            return PlatformFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        let heading = block.type == .heading
        var font = PlatformFont.systemFont(ofSize: size, weight: heading ? .bold : (bold ? .bold : .regular))
        if italic {
            #if os(macOS)
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            #else
            if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            #endif
        }
        return font
    }

    /// Where the text of a paragraph starts.
    public func textIndent(for block: Block) -> CGFloat {
        switch block.type {
        case .bullet, .numbered, .checkbox: return CGFloat(block.depth) * listIndent + markerWidth
        case .quote: return bodySize
        case .code: return bodySize * 0.8
        default: return 0
        }
    }

    public func paragraphStyle(for block: Block, isTitle: Bool, previous: Block?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = textIndent(for: block)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        switch block.type {
        case .heading:
            style.paragraphSpacingBefore = isTitle ? 0 : bodySize * 0.5
            style.paragraphSpacing = bodySize * 0.25
        case .code:
            style.tailIndent = -bodySize * 0.8
            style.paragraphSpacingBefore = previous?.type == .code ? 0 : bodySize * 0.5
        case .image, .table, .file:
            style.paragraphSpacingBefore = bodySize * 0.3
            style.paragraphSpacing = bodySize * 0.3
        default:
            style.paragraphSpacing = bodySize * 0.15
        }
        style.lineHeightMultiple = block.type == .code ? 1.05 : 1.12
        return style
    }

    public var textColor: PlatformColor {
        #if os(macOS)
        return .textColor
        #else
        return .label
        #endif
    }

    public var secondaryColor: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    public var accentColor: PlatformColor { .systemYellow }

    public var codeBackground: PlatformColor {
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
        }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.05) }
        #endif
    }

    public var separatorColor: PlatformColor {
        #if os(macOS)
        return .separatorColor
        #else
        return .separator
        #endif
    }
}
