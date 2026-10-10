import AVFoundation
import NotesMDEditor
import NotesMDKit
import SwiftUI
#if os(iOS)
import QuickLook
#endif

/// What opens when a table, picture or file in a note is tapped. `onSave`
/// puts the edited Markdown of the line in its place, nil takes it away.
struct ObjectSheet: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    let object: OpenedObject
    let note: NoteRecord?
    let onSave: (String?) -> Void

    var body: some View {
        switch object.attachment.kind {
        case .table(let table):
            TableEditor(table: table) { edited in
                onSave(edited.map { Markdown.toMarkdown([MdLine(Block(.table), table: $0)]) })
            }
        case .image(let path, let drawing):
            if let note, let url = model.resolve(path, in: note) {
                if drawing, DrawingDoc.load(strokesOf: url) != nil {
                    DrawingSheet(pictureURL: url) { result in
                        // The same picture, drawn again: written over, its strokes with it.
                        try? result.png.write(to: url, options: .atomic)
                        try? result.strokes.write(to: URL(fileURLWithPath: WireForm.strokesPath(url.path)), options: .atomic)
                        onSave(object.attachment.source)
                    } onDelete: {
                        onSave(nil)
                    }
                } else {
                    ImageViewer(url: url) { onSave(nil) } onRotate: { onSave(object.attachment.source) }
                }
            }
        case .file(let file):
            if let note, let url = model.resolve(file.path, in: note) {
                FileSheet(file: file, url: url) { onSave(nil) }
            }
        }
    }
}

// MARK: - Tables

/// A table as a grid of fields: rows and columns added, moved and taken out.
struct TableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [[String]]
    @State private var selectedRow: Int?
    @State private var selectedColumn: Int?
    let onSave: (MdTable?) -> Void

    init(table: MdTable, onSave: @escaping (MdTable?) -> Void) {
        let columns = max(table.columns, 1)
        _rows = State(initialValue: (table.rows.isEmpty ? [[""]] : table.rows).map { row in (0..<columns).map { $0 < row.count ? row[$0] : "" } })
        self.onSave = onSave
    }

    private var columns: Int { rows.first?.count ?? 1 }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Color.clear.frame(width: 28, height: 24)
                        ForEach(0..<columns, id: \.self) { column in
                            Button { selectedColumn = selectedColumn == column ? nil : column; selectedRow = nil } label: {
                                Capsule().fill(selectedColumn == column ? Color.yellow : Color.secondary.opacity(0.3)).frame(width: 28, height: 6)
                            }
                            .buttonStyle(.plain)
                            .frame(height: 24)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            Button { selectedRow = selectedRow == row ? nil : row; selectedColumn = nil } label: {
                                Capsule().fill(selectedRow == row ? Color.yellow : Color.secondary.opacity(0.3)).frame(width: 6, height: 28)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28)
                            ForEach(0..<columns, id: \.self) { column in
                                TextField("", text: cell(row, column), axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .padding(8)
                                    .frame(minWidth: 120, maxWidth: 260, minHeight: 36, alignment: .topLeading)
                                    .background(selectedRow == row || selectedColumn == column ? Color.yellow.opacity(0.15) : Color.clear)
                                    .border(Color.secondary.opacity(0.35), width: 0.5)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(MdTable(rows: rows.map { $0.map { $0.replacingOccurrences(of: "|", with: "¦").replacingOccurrences(of: "\n", with: " ") } }))
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: toolbarPlacement) {
                    Menu {
                        Button("Add Row") { rows.insert(Array(repeating: "", count: columns), at: (selectedRow ?? rows.count - 1) + 1) }
                        Button("Add Column") {
                            let at = (selectedColumn ?? columns - 1) + 1
                            rows = rows.map { var r = $0; r.insert("", at: at); return r }
                        }
                    } label: { Label("Add", systemImage: "plus") }
                    Button { moveSelection(-1) } label: { Label("Move Back", systemImage: selectedColumn != nil ? "arrow.left" : "arrow.up") }
                        .disabled(selectedRow == nil && selectedColumn == nil)
                    Button { moveSelection(1) } label: { Label("Move Forward", systemImage: selectedColumn != nil ? "arrow.right" : "arrow.down") }
                        .disabled(selectedRow == nil && selectedColumn == nil)
                    Menu {
                        if let row = selectedRow, rows.count > 1 { Button("Delete Row", role: .destructive) { rows.remove(at: row); selectedRow = nil } }
                        if let column = selectedColumn, columns > 1 {
                            Button("Delete Column", role: .destructive) { rows = rows.map { var r = $0; r.remove(at: column); return r }; selectedColumn = nil }
                        }
                        Button("Delete Table", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .bottomBar
        #else
        return .primaryAction
        #endif
    }

    private func cell(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: { row < rows.count && column < rows[row].count ? rows[row][column] : "" },
                set: { if row < rows.count, column < rows[row].count { rows[row][column] = $0 } })
    }

    private func moveSelection(_ step: Int) {
        if let row = selectedRow, rows.indices.contains(row + step) {
            rows.swapAt(row, row + step)
            selectedRow = row + step
        } else if let column = selectedColumn, (0..<columns).contains(column + step) {
            rows = rows.map { var r = $0; r.swapAt(column, column + step); return r }
            selectedColumn = column + step
        }
    }
}

// MARK: - Pictures

/// A picture large, to zoom into, turn, or take out of the note.
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onDelete: () -> Void
    let onRotate: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var version = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    picture
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                }
                .gesture(MagnifyGesture().onChanged { zoom = min(max(base * $0.magnification, 0.7), 6) }.onEnded { _ in base = zoom })
                .onTapGesture(count: 2) {
                    zoom = zoom > 1 ? 1 : 2.5
                    base = zoom
                }
            }
            .background(Color.black.opacity(0.92))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { rotate(left: true) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    Button { rotate(left: false) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    ShareLink(item: url)
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var picture: Image {
        _ = version
        #if os(macOS)
        return NSImage(contentsOf: url).map(Image.init(nsImage:)) ?? Image(systemName: "photo")
        #else
        return UIImage(contentsOfFile: url.path).map(Image.init(uiImage:)) ?? Image(systemName: "photo")
        #endif
    }

    /// Turned and written back over the file, as on the phone; a drawing turned is a picture from then on.
    private func rotate(left: Bool) {
        guard let data = ImageTools.rotated(url: url, left: left) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: WireForm.strokesPath(url.path)))
        version += 1
        onRotate()
    }
}

// MARK: - Files

/// An attached file: opened in the app it belongs to, shared, or taken out.
struct FileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: MdFile
    let url: URL
    let onDelete: () -> Void
    @StateObject private var player = AudioPlayer()
    #if os(iOS)
    @State private var preview: URL?
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: file.isAudio ? "waveform" : "doc")
                    .font(.system(size: 48))
                    .foregroundStyle(file.isAudio ? .orange : .blue)
                Text(file.name).font(.headline).multilineTextAlignment(.center)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).foregroundStyle(.secondary)
                }
                if file.isAudio {
                    HStack {
                        Button { player.toggle(url) } label: {
                            Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                        }
                        .buttonStyle(.plain)
                        ProgressView(value: player.progress).frame(width: 200)
                    }
                }
                HStack(spacing: 12) {
                    Button("Open") { open() }.buttonStyle(.borderedProminent)
                    ShareLink(item: url)
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .padding(30)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(iOS)
        .quickLookPreview($preview)
        #endif
        .frame(minWidth: 380, minHeight: 280)
        .onDisappear { player.stop() }
    }

    private func open() {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        preview = url
        #endif
    }
}

/// Plays a recording in the note.
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playing {
            player?.pause()
            playing = false
            return
        }
        if player == nil {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            #endif
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        player?.play()
        playing = player?.isPlaying ?? false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        playing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.progress = 0
            self.timer?.invalidate()
        }
    }
}
