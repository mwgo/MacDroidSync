import Foundation
import NotesMDKit

#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias TextEditActions = NSTextStorageEditActions
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias TextEditActions = NSTextStorage.EditActions
#endif

extension NSAttributedString.Key {
    /// The block a paragraph is, on every character of it, its newline included: `Block.encoded`.
    public static let mdBlock = NSAttributedString.Key("md.block")
    public static let mdBold = NSAttributedString.Key("md.bold")
    public static let mdItalic = NSAttributedString.Key("md.italic")
    public static let mdUnderline = NSAttributedString.Key("md.underline")
    public static let mdCode = NSAttributedString.Key("md.code")
    /// On the one character of a table, picture or file: its Markdown, as it is written.
    public static let mdObject = NSAttributedString.Key("md.object")
    /// On the first character of a heading whose section is folded away. Not part of the Markdown.
    public static let mdFolded = NSAttributedString.Key("md.folded")
}

extension InlineKind {
    public var key: NSAttributedString.Key {
        switch self {
        case .bold: return .mdBold
        case .italic: return .mdItalic
        case .underline: return .mdUnderline
        case .code: return .mdCode
        }
    }

    public static let all: [InlineKind] = [.bold, .italic, .underline, .code]
}

extension Block {
    /// How a block rides on the text as an attribute.
    public var encoded: String { "\(type.rawValue):\(level):\(checked ? 1 : 0):\(depth)" }

    public init(encoded: String) {
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        let type = parts.first.flatMap { BlockType(rawValue: String($0)) } ?? .paragraph
        let level = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let checked = parts.count > 2 && parts[2] == "1"
        let depth = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
        self.init(type, level: level, checked: checked, depth: depth)
    }

    /// One of the things that stand on a line of their own as one character.
    public var isObject: Bool { type == .table || type == .image || type == .file }
}

/// The character a table, picture or file stands as.
public let objectCharacter: Character = "\u{FFFC}"
public let objectUnit: unichar = 0xFFFC

#if os(macOS)
extension NSFont {
    /// As UIFont has it.
    public var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}
#endif
