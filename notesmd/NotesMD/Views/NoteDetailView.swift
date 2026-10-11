import NotesMDEditor
import NotesMDKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One note open: its editor, saved 1.5 s after typing stops and when the
/// note is left, and read again when it changed elsewhere while nothing here
/// waits to be saved.
struct NoteDetailView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var editor: EditorController
    let noteId: String

    @State private var markdown = ""
    @State private var key = ""
    @State private var baseSHA: String?
    @State private var unsaved: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    @State private var loaded = false

    @State private var importing = false
    @State private var showSource = false
    @State private var moving = false
    @State private var opened: OpenedObject?
    @State private var drawing = false
    @State private var recording = false
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var camera = false
    #endif

    private var note: NoteRecord? { model.note(noteId) }
    private var inTrash: Bool { note?.trashed != nil }

    var body: some View {
        Group {
            if loaded, let note {
                NoteEditorView(
                    key: key,
                    markdown: markdown,
                    editable: !inTrash,
                    info: NoteInfo(date: note.modified.formatted(date: .long, time: .shortened), folder: note.folder),
                    resolve: { [weak model] link in model?.resolve(link, in: note) },
                    controller: editor,
                    onChange: changed,
                    onObjectTap: { attachment, location in opened = OpenedObject(attachment: attachment, location: location) }
                )
                // Under the bars: the note scrolls on beneath the glass, which blurs it at its edge.
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .task(id: noteId) { await load() }
        .onDisappear { leave() }
        .onChange(of: model.snapshot) { _, _ in reloadIfChangedElsewhere() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attach(urls) }
        }
        .sheet(isPresented: $showSource) {
            SourceSheet(markdown: editor.markdown() ?? markdown) { edited in
                apply(edited)
            }
        }
        .sheet(isPresented: $moving) { MoveSheet(noteId: noteId) }
        .sheet(isPresented: $drawing) {
            DrawingSheet(pictureURL: nil) { result in Task { await insertDrawing(result) } }
        }
        .sheet(isPresented: $recording) {
            RecordSheet { url in
                Task {
                    if let line = await model.attach(url, to: noteId, asFile: true) { editor.insert(line) }
                }
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self), let url = PictureFiles.jpeg(data) else { continue }
                    if let line = await model.attach(url, to: noteId, asFile: false) { editor.insert(line) }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.95), let url = PictureFiles.jpeg(data) else { return }
                Task { if let line = await model.attach(url, to: noteId, asFile: false) { editor.insert(line) } }
            }
            .ignoresSafeArea()
        }
        #endif
        .sheet(item: $opened) { object in
            ObjectSheet(object: object, note: note) { source in
                editor.replaceObject(at: object.location, with: source)
            }
        }
    }

    // MARK: - Loading and saving

    private func load() async {
        guard let note, let text = await model.read(noteId) else { return }
        markdown = text
        baseSHA = note.sha
        key = noteId + "|" + note.sha
        unsaved = nil
        loaded = true
    }

    private func changed(_ text: String) {
        unsaved = text
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save(rename: !editor.isEditing || !inTitle)
        }
    }

    private var inTitle: Bool { editor.inTitle }

    private func save(rename: Bool) async {
        guard let text = unsaved, !saving else { return }
        saving = true
        defer { saving = false }
        if let saved = await model.save(noteId, markdown: text, baseSHA: baseSHA, rename: rename) {
            baseSHA = saved.sha
            if unsaved == text { unsaved = nil }
        }
    }

    /// Leaving the note: what is not saved is, under its title's name; a note left empty goes.
    private func leave() {
        saveTask?.cancel()
        let text = unsaved ?? editor.markdown() ?? markdown
        let id = noteId
        let base = baseSHA
        let pending = unsaved
        Task {
            if let pending { _ = await model.save(id, markdown: pending, baseSHA: base, rename: true) } else if let note = model.note(id),
                note.trashed == nil, FileNames.base(forTitle: Markdown.title(text)) != note.fileBase,
                !FileNames.isVariant(note.fileBase, of: FileNames.base(forTitle: Markdown.title(text))) {
                _ = await model.save(id, markdown: text, baseSHA: base, rename: true)
            }
            await model.discardIfBlank(id, markdown: text)
        }
    }

    private func reloadIfChangedElsewhere() {
        guard loaded, !saving, unsaved == nil, let note, note.sha != baseSHA, !note.sha.isEmpty else { return }
        Task { await load() }
    }

    private func apply(_ edited: String) {
        unsaved = edited
        markdown = edited
        key = noteId + "|edited|" + UUID().uuidString
        Task { await save(rename: true) }
    }

    // MARK: - Attachments

    private func attach(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            let picture = type?.conforms(to: .image) == true
            if let line = await model.attach(url, to: noteId, asFile: !picture) { editor.insert(line) }
        }
    }

    /// A new drawing: its picture into the note, its strokes next to it.
    private func insertDrawing(_ result: DrawingResult) async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? result.png.write(to: temp)) != nil,
              let line = await model.attach(temp, to: noteId, asFile: false, drawing: true),
              let image = Markdown.parseImage(line), let note else { return }
        let path = FileNames.decodeLink(image.path)
        if path.hasPrefix(note.assetsFolder + "/") {
            let inner = WireForm.strokesPath(String(path.dropFirst(note.assetsFolder.count + 1)))
            await model.writeAsset(of: noteId, inner: inner, data: result.strokes)
        }
        editor.insert(line)
    }

    private func insertTable() {
        editor.insert("|  |  |\n| --- | --- |\n|  |  |")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if inTrash {
            ToolbarItem(placement: .primaryAction) {
                Button("Recover") { Task { await model.restore(noteId) } }
            }
        } else {
            #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                foldAllButton
                FormatMenu()
                Button { editor.toggleBlock(.checkbox) } label: { Label("Checklist", systemImage: "checklist") }
                Button { insertTable() } label: { Label("Table", systemImage: "tablecells") }
                attachMenu
                moreMenu
            }
            #else
            if isPad {
                // iPad: everything at the top, as Notes has it there.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    foldAllButton
                    FormatMenu()
                    Button { editor.toggleBlock(.checkbox) } label: { Label("Checklist", systemImage: "checklist") }
                    Button { insertTable() } label: { Label("Table", systemImage: "tablecells") }
                    attachMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let note {
                        Button { Task { await model.setPinned(noteId, !note.pinned) } } label: {
                            Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
                        }
                    }
                    moreMenu
                    Button { Task { await model.newNote(in: note?.folder) } } label: { Label("New Note", systemImage: "square.and.pencil") }
                    if editor.isEditing {
                        Button("Done") { editor.endEditing() }.bold()
                    }
                }
            } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let note {
                    Button { Task { await model.setPinned(noteId, !note.pinned) } } label: {
                        Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
                    }
                }
                moreMenu
                if editor.isEditing {
                    Button("Done") { editor.endEditing() }.bold()
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { editor.toggleBlock(.checkbox) } label: { Label("Checklist", systemImage: "checklist") }
                Spacer()
                Button { insertTable() } label: { Label("Table", systemImage: "tablecells") }
                Spacer()
                attachMenu
                Spacer()
                Button { Task { await model.newNote(in: note?.folder) } } label: { Label("New Note", systemImage: "square.and.pencil") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                FormatMenu()
                Spacer()
                Button { editor.toggleBlock(.checkbox) } label: { Image(systemName: "checklist") }
                Spacer()
                Button { insertTable() } label: { Image(systemName: "tablecells") }
                Spacer()
                attachMenu
                Spacer()
                Button { editor.outdent() } label: { Image(systemName: "decrease.indent") }
                Button { editor.indent() } label: { Image(systemName: "increase.indent") }
            }
            }
            #endif
        }
    }

    /// Folds every heading of the note, or unfolds them all, as on the phone.
    private var foldAllButton: some View {
        Button { editor.toggleAllFolds() } label: {
            Label(editor.allFolded ? "Expand All Headings" : "Collapse All Headings",
                  systemImage: editor.allFolded ? "arrow.up.and.line.horizontal.and.arrow.down" : "arrow.down.and.line.horizontal.and.arrow.up")
        }
        .help(editor.allFolded ? "Expand All Headings" : "Collapse All Headings")
        .disabled(!editor.canFoldAll)
    }

    private var attachMenu: some View {
        Menu {
            Button { choosingPhotos = true } label: { Label("Choose Photo", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            Button { camera = true } label: { Label("Take Photo", systemImage: "camera") }
            #endif
            Button { importing = true } label: { Label("Attach File…", systemImage: "paperclip") }
            Divider()
            Button { drawing = true } label: { Label("Drawing", systemImage: "pencil.tip.crop.circle") }
            Button { recording = true } label: { Label("Record Audio", systemImage: "mic") }
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
    }

    private var moreMenu: some View {
        Menu {
            if let note {
                #if os(macOS)
                Button(note.pinned ? "Unpin Note" : "Pin Note") { Task { await model.setPinned(noteId, !note.pinned) } }
                #endif
                Button { moving = true } label: { Label("Move to Folder…", systemImage: "folder") }
                Button { Task { await model.duplicate(noteId) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { showSource = true } label: { Label("Show Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
                if editor.tasks.all > 0 {
                    Text(editor.tasks.open == 0 ? "All \(editor.tasks.all) tasks done" : "\(editor.tasks.open) of \(editor.tasks.all) tasks to do")
                }
                Divider()
                Button(role: .destructive) { Task { await model.delete(noteId) } } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}

/// The text styles and lists, as the Aa button of Notes offers them.
struct FormatMenu: View {
    @EnvironmentObject private var editor: EditorController

    var body: some View {
        Menu {
            Section {
                Button { editor.toggleBlock(.heading) } label: { check("Heading", editor.block.type == .heading) }
                Button { editor.cycleHeading() } label: { Text("Next Heading Level") }
                Button { editor.toggleBlock(.code) } label: { check("Monospaced", editor.block.type == .code) }
            }
            Section {
                Button { editor.toggle(.bold) } label: { check("Bold", editor.active.contains(.bold)) }
                Button { editor.toggle(.italic) } label: { check("Italic", editor.active.contains(.italic)) }
                Button { editor.toggle(.underline) } label: { check("Underline", editor.active.contains(.underline)) }
                Button { editor.toggle(.code) } label: { check("Code", editor.active.contains(.code)) }
            }
            Section {
                Button { editor.toggleBlock(.bullet) } label: { check("Bulleted List", editor.block.type == .bullet) }
                Button { editor.toggleBlock(.numbered) } label: { check("Numbered List", editor.block.type == .numbered) }
                Button { editor.toggleBlock(.checkbox) } label: { check("Checklist", editor.block.type == .checkbox) }
                Button { editor.toggleBlock(.quote) } label: { check("Block Quote", editor.block.type == .quote) }
            }
            Section {
                Button { editor.indent() } label: { Label("Indent", systemImage: "increase.indent") }
                Button { editor.outdent() } label: { Label("Outdent", systemImage: "decrease.indent") }
            }
        } label: {
            Label("Format", systemImage: "textformat")
        }
    }

    private func check(_ title: String, _ on: Bool) -> some View {
        Label(title, systemImage: on ? "checkmark" : "")
    }
}

/// The note's Markdown, to read or edit as text.
struct SourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var markdown: String
    let onSave: (String) -> Void

    init(markdown: String, onSave: @escaping (String) -> Void) {
        _markdown = State(initialValue: markdown)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $markdown)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .navigationTitle("Markdown")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(markdown)
                            dismiss()
                        }
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

/// A table, picture or file tapped in a note.
struct OpenedObject: Identifiable {
    let id = UUID()
    let attachment: NoteAttachment
    let location: Int
}
