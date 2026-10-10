import Foundation
import NotesMDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A table, picture or file standing in a note as one character.
public final class NoteAttachment: NSTextAttachment {
    public enum Kind: Equatable {
        case image(path: String, drawing: Bool)
        case file(MdFile)
        case table(MdTable)
    }

    public let kind: Kind
    /// The Markdown of the line, as written back.
    public let source: String
    /// The size the content would like; the line's width may make it smaller.
    var natural: CGSize

    init(kind: Kind, source: String, image: PlatformImage?, natural: CGSize) {
        self.kind = kind
        self.source = source
        self.natural = natural
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    required init?(coder: NSCoder) {
        fatalError("not coded")
    }

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let available = max(lineFrag.width - 2 * (textContainer?.lineFragmentPadding ?? 0) - 2, 40)
        var size = natural
        switch kind {
        case .image:
            if size.width > available {
                size = CGSize(width: available, height: size.height * available / size.width)
            }
            if size.height > available * 1.25 {
                size = CGSize(width: size.width * available * 1.25 / size.height, height: available * 1.25)
            }
        case .file:
            size.width = min(available, 420)
        case .table:
            if size.width > available {
                size = CGSize(width: available, height: size.height * available / size.width)
            }
        }
        return CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded()))
    }
}

/// Makes the attachments of a note: pictures from its folder, tiles for its files, grids for its tables.
public struct AttachmentMaker {
    public var style: EditorStyle
    /// Where a link of the note points.
    public var resolve: (String) -> URL?

    public init(style: EditorStyle, resolve: @escaping (String) -> URL?) {
        self.style = style
        self.resolve = resolve
    }

    public func attachment(for line: MdLine, source: String) -> NoteAttachment {
        if let image = line.image {
            let picture = resolve(image.path).flatMap { PlatformImage(contentsOfFile: $0.path) }
            let size = picture?.size ?? CGSize(width: 240, height: 160)
            return NoteAttachment(
                kind: .image(path: image.path, drawing: image.isDrawing),
                source: source,
                image: picture ?? placeholder(CGSize(width: 240, height: 160), label: "Picture not downloaded yet"),
                natural: size
            )
        }
        if let file = line.file {
            let size = CGSize(width: 420, height: (style.bodySize * 4).rounded())
            return NoteAttachment(kind: .file(file), source: source, image: fileTile(file, size: size), natural: size)
        }
        let table = line.table ?? MdTable(rows: [[""]])
        let (image, size) = tableImage(table)
        return NoteAttachment(kind: .table(table), source: source, image: image, natural: size)
    }

    // MARK: - Drawing

    private func render(_ size: CGSize, _ draw: @escaping (CGRect) -> Void) -> PlatformImage {
        #if os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
        #else
        let format = UIGraphicsImageRendererFormat.default()
        func variant(_ style: UIUserInterfaceStyle) -> UIImage {
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                image = UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(CGRect(origin: .zero, size: size)) }
            }
            return image
        }
        let light = variant(.light)
        let dark = variant(.dark)
        let asset = UIImageAsset()
        asset.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection.current)
        #endif
    }

    private func placeholder(_ size: CGSize, label: String) -> PlatformImage {
        let style = style
        return render(size) { rect in
            let path = bezier(roundedRect: rect.insetBy(dx: 1, dy: 1), radius: 10)
            style.codeBackground.setFill()
            path.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: style.bodySize - 2), .foregroundColor: style.secondaryColor]
            let text = label as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    /// A file as Notes shows one: a badge with its type, its name, its type and size.
    private func fileTile(_ file: MdFile, size: CGSize) -> PlatformImage {
        let style = style
        let url = resolve(file.path)
        let bytes = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        let detail = [file.fileExtension.uppercased(), bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return render(size) { rect in
            let card = bezier(roundedRect: rect.insetBy(dx: 1, dy: 1), radius: 12)
            style.codeBackground.setFill()
            card.fill()
            let badgeSide = rect.height - 20
            let badge = CGRect(x: 10, y: 10, width: badgeSide, height: badgeSide)
            (file.isAudio ? PlatformColor.systemOrange : PlatformColor.systemBlue).setFill()
            bezier(roundedRect: badge, radius: 8).fill()
            let mark = (file.isAudio ? "▶︎" : String(file.fileExtension.prefix(4)).uppercased()) as NSString
            let markAttributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: file.isAudio ? badgeSide * 0.45 : badgeSide * 0.26, weight: .bold),
                .foregroundColor: PlatformColor.white,
            ]
            let markSize = mark.size(withAttributes: markAttributes)
            mark.draw(at: CGPoint(x: badge.midX - markSize.width / 2, y: badge.midY - markSize.height / 2), withAttributes: markAttributes)
            let textX = badge.maxX + 12
            let width = rect.width - textX - 12
            let name = NSAttributedString(string: file.name, attributes: [
                .font: PlatformFont.systemFont(ofSize: style.bodySize, weight: .medium),
                .foregroundColor: style.textColor,
            ])
            name.draw(with: CGRect(x: textX, y: rect.midY - style.bodySize * 1.3, width: width, height: style.bodySize * 1.4),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            let info = NSAttributedString(string: detail, attributes: [
                .font: PlatformFont.systemFont(ofSize: style.bodySize - 2),
                .foregroundColor: style.secondaryColor,
            ])
            info.draw(with: CGRect(x: textX, y: rect.midY + 2, width: width, height: style.bodySize * 1.3),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    /// A table as a grid with thin lines, every row alike.
    private func tableImage(_ table: MdTable) -> (PlatformImage, CGSize) {
        let style = style
        let font = PlatformFont.systemFont(ofSize: style.bodySize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.textColor]
        let columns = max(table.columns, 1)
        let padding: CGFloat = 8
        var widths = [CGFloat](repeating: 40, count: columns)
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < columns {
                let text = Markdown.inlineText(cell) as NSString
                widths[index] = min(max(widths[index], text.size(withAttributes: attributes).width + 2 * padding), 320)
            }
        }
        let rowHeight = (font.pointSize * 1.3 + 2 * padding).rounded()
        let size = CGSize(width: widths.reduce(0, +) + 2, height: CGFloat(max(table.rows.count, 1)) * rowHeight + 2)
        let image = render(size) { rect in
            var y: CGFloat = 1
            for row in table.rows {
                var x: CGFloat = 1
                for column in 0..<columns {
                    let cell = CGRect(x: x, y: y, width: widths[column], height: rowHeight)
                    let text = column < row.count ? Markdown.inlineText(row[column]) : ""
                    NSAttributedString(string: text, attributes: attributes).draw(
                        with: cell.insetBy(dx: padding, dy: padding),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        context: nil
                    )
                    x += widths[column]
                }
                y += rowHeight
            }
            style.separatorColor.setStroke()
            let grid = bezier()
            var lineY: CGFloat = 1
            for _ in 0...table.rows.count {
                grid.move(to: CGPoint(x: 1, y: lineY))
                grid.addLine(to: CGPoint(x: size.width - 1, y: lineY))
                lineY += rowHeight
            }
            var lineX: CGFloat = 1
            for column in 0...columns {
                grid.move(to: CGPoint(x: lineX, y: 1))
                grid.addLine(to: CGPoint(x: lineX, y: size.height - 1))
                if column < columns { lineX += widths[column] }
            }
            grid.lineWidth = 1
            grid.stroke()
        }
        return (image, size)
    }
}

#if os(macOS)
typealias PlatformBezier = NSBezierPath
func bezier(roundedRect rect: CGRect, radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }
func bezier() -> NSBezierPath { NSBezierPath() }
extension NSBezierPath {
    func addLine(to point: CGPoint) { line(to: point) }
}
#else
typealias PlatformBezier = UIBezierPath
func bezier(roundedRect rect: CGRect, radius: CGFloat) -> UIBezierPath { UIBezierPath(roundedRect: rect, cornerRadius: radius) }
func bezier() -> UIBezierPath { UIBezierPath() }
#endif
