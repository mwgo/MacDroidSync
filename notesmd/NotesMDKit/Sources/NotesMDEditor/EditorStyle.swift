import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a note looks: a large bold title over a line of when and where, amber
/// sections, black subsections and small grey capitals below them, the text
/// in the system font, monospace for code. The title is `#`, the sections
/// `##`, so a heading's rank counts from there.
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

    /// A heading's rank under the title: 1 for a section (`#` or `##`), 2 for `###`, 3 below.
    public static func rank(of block: Block) -> Int {
        max(1, min(block.level, 4) - 1)
    }

    public func size(of block: Block, isTitle: Bool) -> CGFloat {
        guard block.type == .heading else { return block.type == .code ? bodySize - 1 : bodySize }
        if isTitle { return (bodySize * 2).rounded() }
        switch Self.rank(of: block) {
        case 1: return (bodySize * 1.45).rounded()
        case 2: return (bodySize * 1.2).rounded()
        default: return (bodySize * 0.87).rounded()
        }
    }

    /// Small capitals for the lowest headings.
    public func isCaps(_ block: Block, isTitle: Bool) -> Bool {
        block.type == .heading && !isTitle && Self.rank(of: block) >= 3
    }

    public func headingColor(_ block: Block, isTitle: Bool) -> PlatformColor {
        if isTitle { return textColor }
        switch Self.rank(of: block) {
        case 1: return accentColor
        case 2: return textColor
        default: return mutedColor
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
        if isCaps(block, isTitle: isTitle) {
            #if os(macOS)
            let caps: [[PlatformFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
                [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector],
            ]
            #else
            let caps: [[PlatformFontDescriptor.FeatureKey: Int]] = [
                [.type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector],
                [.type: kUpperCaseType, .selector: kUpperCaseSmallCapsSelector],
            ]
            #endif
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: caps])
            #if os(macOS)
            font = NSFont(descriptor: descriptor, size: size) ?? font
            #else
            font = UIFont(descriptor: descriptor, size: size)
            #endif
        }
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
        case .heading where isTitle:
            style.paragraphSpacing = titleSpacing
        case .heading:
            switch Self.rank(of: block) {
            case 1: style.paragraphSpacingBefore = bodySize * 1.4
            case 2: style.paragraphSpacingBefore = bodySize * 1.1
            default: style.paragraphSpacingBefore = bodySize * 1.0
            }
            style.paragraphSpacing = bodySize * 0.35
        case .code:
            style.tailIndent = -bodySize * 0.8
            style.paragraphSpacingBefore = previous?.type == .code ? 0 : bodySize * 0.6
        case .image, .table, .file:
            style.paragraphSpacingBefore = bodySize * 0.6
            style.paragraphSpacing = bodySize * 0.6
        case .bullet, .numbered, .checkbox:
            style.paragraphSpacing = bodySize * 0.25
        default:
            style.paragraphSpacing = bodySize * 0.3
        }
        style.lineHeightMultiple = block.type == .heading ? 1.0 : (block.type == .code ? 1.05 : 1.2)
        return style
    }

    // MARK: - Under the title: when and where

    public var infoSize: CGFloat { (bodySize * 0.8).rounded() }
    /// From the title to its line of information, and from that to the rule under it.
    public var infoGap: CGFloat { bodySize * 0.4 }
    public var ruleGap: CGFloat { bodySize * 0.8 }
    /// The room the title leaves below it: its line of information, the rule, and a gap to the text.
    public var titleSpacing: CGFloat {
        infoGap + PlatformFont.systemFont(ofSize: infoSize).lineHeight + ruleGap + 1 + bodySize * 1.2
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

    /// Notes MD's amber: sections, the folder, ticked boxes.
    public var accentColor: PlatformColor { dynamic(light: 0xC7610F, dark: 0xF0973A) }
    /// The lowest headings and the date under the title.
    public var mutedColor: PlatformColor { dynamic(light: 0x8A8A8E, dark: 0x98989D) }
    public var chevronColor: PlatformColor { dynamic(light: 0xAEAEB2, dark: 0x6E6E73) }
    public var ruleColor: PlatformColor { dynamic(light: 0xECE6DE, dark: 0x3A3532) }
    public var quoteBarColor: PlatformColor { dynamic(light: 0xE2DDD6, dark: 0x4A433C) }
    public var inlineCodeBackground: PlatformColor { dynamic(light: 0xF7EFE6, dark: 0x3A2E24) }
    public var inlineCodeColor: PlatformColor { dynamic(light: 0x8A3B06, dark: 0xFFC08A) }
    /// The ring of a box not ticked.
    public var boxColor: PlatformColor { dynamic(light: 0xC7C7CC, dark: 0x636366) }
    /// The tick in a ticked box, on the amber.
    public var tickColor: PlatformColor { dynamic(light: 0xFFFFFF, dark: 0x1E1E1E) }

    private func dynamic(light: UInt32, dark: UInt32) -> PlatformColor {
        func color(_ hex: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        #if os(macOS)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
        #endif
    }

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
