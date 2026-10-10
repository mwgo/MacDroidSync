import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A drawing's strokes, in the JSON the phone writes next to the picture
/// (DrawingView.kt): `{width, sheet, strokes: [{color, size, shape?, points}]}`,
/// in units of a view `width` wide, so that a screen of another width scales
/// them. `color` is ARGB as a signed 32-bit number; a stroke without `shape`
/// is drawn by hand, a shape keeps only where it started and ended.
public struct DrawingDoc: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable {
        case pen, line, arrow, rectangle, oval
    }

    public struct Stroke: Codable, Equatable, Sendable {
        public var color: Int32
        public var size: Double
        public var shape: Shape?
        public var points: [Double]

        public init(color: Int32, size: Double, shape: Shape?, points: [Double]) {
            self.color = color
            self.size = size
            self.shape = shape == .pen ? nil : shape
            self.points = points
        }

        public var kind: Shape { shape ?? .pen }
    }

    public var width: Double
    public var sheet: Double
    public var strokes: [Stroke]

    public init(width: Double, sheet: Double, strokes: [Stroke] = []) {
        self.width = width
        self.sheet = sheet
        self.strokes = strokes
    }

    /// The six colours of the phone's drawing tools.
    public static let palette: [UInt32] = [0xFF1C1B1F, 0xFFE53935, 0xFFFB8C00, 0xFF43A047, 0xFF1E88E5, 0xFF8E24AA]
    /// The three brush sizes, at the width of a phone screen.
    public static let sizes: [Double] = [2, 5, 10]

    /// The strokes kept next to a picture, if it is a drawing that has them.
    public static func load(strokesOf picture: URL) -> DrawingDoc? {
        let url = URL(fileURLWithPath: WireForm.strokesPath(picture.path))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DrawingDoc.self, from: data)
    }

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The drawing at another width.
    public func scaled(toWidth newWidth: Double) -> DrawingDoc {
        let scale = newWidth / max(width, 1)
        return DrawingDoc(
            width: newWidth,
            sheet: sheet * scale,
            strokes: strokes.map { Stroke(color: $0.color, size: $0.size * scale, shape: $0.shape, points: $0.points.map { $0 * scale }) }
        )
    }

    public static func cgColor(_ argb: Int32) -> CGColor {
        let value = UInt32(bitPattern: argb)
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat((value >> 24) & 0xFF) / 255
        )
    }

    /// The path of one stroke as the phone draws it: by hand through the
    /// middle of each step, a shape from corner to corner or end to end.
    public static func path(_ stroke: Stroke, headMin: Double = 12) -> CGPath {
        let path = CGMutablePath()
        let p = stroke.points
        guard p.count >= 2 else { return path }
        switch stroke.kind {
        case .pen:
            var last = CGPoint(x: p[0], y: p[1])
            path.move(to: last)
            path.addLine(to: CGPoint(x: last.x + 0.1, y: last.y))
            var i = 2
            while i + 1 < p.count {
                let point = CGPoint(x: p[i], y: p[i + 1])
                if i + 2 >= p.count {
                    path.addLine(to: point)
                } else {
                    path.addQuadCurve(to: CGPoint(x: (point.x + last.x) / 2, y: (point.y + last.y) / 2), control: last)
                }
                last = point
                i += 2
            }
        case .rectangle, .oval:
            guard p.count >= 4 else { return path }
            let box = CGRect(x: min(p[0], p[2]), y: min(p[1], p[3]), width: abs(p[2] - p[0]), height: abs(p[3] - p[1]))
            if stroke.kind == .rectangle { path.addRect(box) } else { path.addEllipse(in: box) }
        case .line, .arrow:
            guard p.count >= 4 else { return path }
            let start = CGPoint(x: p[0], y: p[1])
            let end = CGPoint(x: p[2], y: p[3])
            path.move(to: start)
            path.addLine(to: end)
            let length = hypot(end.x - start.x, end.y - start.y)
            if stroke.kind == .arrow, length > 0 {
                let head = min(max(stroke.size * 3, headMin), length / 2)
                let angle = atan2(end.y - start.y, end.x - start.x)
                for side in [-1.0, 1.0] {
                    let a = angle + .pi + side * .pi / 7
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x + head * cos(a), y: end.y + head * sin(a)))
                }
            }
        }
        return path
    }

    /// The sheet as it goes into the note: white, the strokes on it, cut at its
    /// line; PNG at `scale` pixels per unit. Nil when nothing is drawn.
    public func png(scale: Double = 2) -> Data? {
        guard !strokes.isEmpty else { return nil }
        let pixelWidth = max(Int(width * scale), 1)
        let pixelHeight = max(Int(sheet * scale), 1)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Top-down, as the points are.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.addPath(Self.path(stroke))
            context.setStrokeColor(Self.cgColor(stroke.color))
            context.setLineWidth(stroke.size)
            context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
