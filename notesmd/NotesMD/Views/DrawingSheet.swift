import ImageIO
import NotesMDKit
import SwiftUI
import UniformTypeIdentifiers

/// A sheet to draw on, as on the phone: by hand or in lines, arrows,
/// rectangles and ovals, six colours, three sizes, and a sheet whose height a
/// handle at its line sets. Drawn again later from its strokes.
struct DrawingSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The picture of the drawing being edited, nil for a new one.
    let pictureURL: URL?
    /// The finished drawing: its picture and its strokes.
    let onDone: (DrawingResult) -> Void
    var onDelete: (() -> Void)?

    @State private var doc = DrawingDoc(width: 0, sheet: 0)
    @State private var current: DrawingDoc.Stroke?
    @State private var shape: DrawingDoc.Shape = .pen
    @State private var color: UInt32 = DrawingDoc.palette[0]
    @State private var size: Double = DrawingDoc.sizes[1]
    @State private var resizing = false
    @State private var ready = false

    private let minSheet: Double = 96

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let width = Double(geometry.size.width)
                ZStack(alignment: .top) {
                    Color.gray.opacity(0.35)
                    Canvas { context, _ in
                        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: doc.sheet)), with: .color(.white))
                        context.clip(to: Path(CGRect(x: 0, y: 0, width: width, height: doc.sheet)))
                        for stroke in doc.strokes + (current.map { [$0] } ?? []) {
                            context.stroke(
                                Path(DrawingDoc.path(stroke)),
                                with: .color(Color(cgColor: DrawingDoc.cgColor(stroke.color))),
                                style: StrokeStyle(lineWidth: stroke.size, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    Rectangle().fill(Color.secondary).frame(height: 1.5).offset(y: doc.sheet)
                    Capsule().fill(Color.secondary).frame(width: 44, height: 6).offset(y: doc.sheet - 3)
                }
                .contentShape(Rectangle())
                .gesture(drag(height: Double(geometry.size.height)))
                .onAppear { start(width: width, height: Double(geometry.size.height)) }
            }
            .navigationTitle("Drawing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private func start(width: Double, height: Double) {
        guard !ready, width > 0 else { return }
        ready = true
        if let pictureURL, let saved = DrawingDoc.load(strokesOf: pictureURL) {
            doc = saved.scaled(toWidth: width)
            doc.sheet = min(max(doc.sheet, minSheet), height - 12)
        } else {
            doc = DrawingDoc(width: width, sheet: max(height * 0.45, minSheet))
        }
    }

    private func drag(height: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location
                if current == nil && !resizing {
                    if abs(Double(value.startLocation.y) - doc.sheet) < 28 {
                        resizing = true
                    } else if Double(value.startLocation.y) < doc.sheet {
                        let start = [Double(value.startLocation.x), Double(value.startLocation.y)]
                        current = DrawingDoc.Stroke(
                            color: Int32(bitPattern: color), size: size, shape: shape,
                            points: shape == .pen ? start : start + start
                        )
                    }
                }
                if resizing {
                    doc.sheet = min(max(Double(point.y), minSheet), height - 12)
                } else if var stroke = current {
                    if stroke.kind == .pen {
                        stroke.points += [Double(point.x), Double(point.y)]
                    } else {
                        stroke.points[2] = Double(point.x)
                        stroke.points[3] = Double(point.y)
                    }
                    current = stroke
                }
            }
            .onEnded { _ in
                resizing = false
                guard let stroke = current else { return }
                current = nil
                if stroke.kind != .pen, hypot(stroke.points[2] - stroke.points[0], stroke.points[3] - stroke.points[1]) < 4 { return }
                doc.strokes.append(stroke)
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                if let png = doc.png() {
                    onDone(DrawingResult(png: png, strokes: doc.json()))
                } else if pictureURL != nil {
                    onDelete?()
                }
                dismiss()
            }
        }
        ToolbarItemGroup(placement: toolsPlacement) {
            Picker("Tool", selection: $shape) {
                Image(systemName: "pencil.tip").tag(DrawingDoc.Shape.pen)
                Image(systemName: "line.diagonal").tag(DrawingDoc.Shape.line)
                Image(systemName: "arrow.up.right").tag(DrawingDoc.Shape.arrow)
                Image(systemName: "rectangle").tag(DrawingDoc.Shape.rectangle)
                Image(systemName: "oval").tag(DrawingDoc.Shape.oval)
            }
            .pickerStyle(.segmented)
            Menu {
                ForEach(DrawingDoc.palette, id: \.self) { value in
                    Button { color = value } label: {
                        Label(value == color ? "✓" : " ", systemImage: "circle.fill")
                    }
                    .tint(Color(cgColor: DrawingDoc.cgColor(Int32(bitPattern: value))))
                }
            } label: {
                Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: DrawingDoc.cgColor(Int32(bitPattern: color))))
            }
            Picker("Size", selection: $size) {
                ForEach(DrawingDoc.sizes, id: \.self) { value in
                    Image(systemName: "circle.fill").font(.system(size: 4 + value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            Button { if !doc.strokes.isEmpty { doc.strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(doc.strokes.isEmpty)
        }
    }

    private var toolsPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .bottomBar
        #else
        return .primaryAction
        #endif
    }
}

struct DrawingResult {
    var png: Data
    var strokes: Data
}

/// Turning a picture a quarter round, as the phone does in its viewer.
enum ImageTools {
    static func rotated(url: URL, left: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.height
        let height = image.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: left ? .pi / 2 : -.pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let turned = context.makeImage() else { return nil }
        let data = NSMutableData()
        let type = CGImageSourceGetType(source) ?? UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, turned, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
