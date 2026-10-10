import NotesMDKit
import SwiftUI

/// The notes of the folder shown, as a list or as a gallery.
struct NoteListView: View {
    @EnvironmentObject private var model: NotesModel
    @State private var moving: String?

    var body: some View {
        Group {
            if model.gallery {
                gallery
            } else {
                list
            }
        }
        .navigationTitle(model.scopeTitle)
        .searchable(text: $model.search, prompt: "Search")
        .overlay {
            if model.visible.isEmpty {
                Text(model.search.isEmpty ? (model.scope == .trash ? "No Deleted Notes" : "No Notes") : "No Results")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { viewMenu }
            ToolbarItem(placement: .bottomBar) { Spacer() }
            ToolbarItem(placement: .bottomBar) { newNoteButton }
            #else
            ToolbarItem { viewMenu }
            ToolbarItem { newNoteButton }
            #endif
        }
        .sheet(item: Binding(get: { moving.map(IdBox.init) }, set: { moving = $0?.id })) { box in
            MoveSheet(noteId: box.id)
        }
    }

    private var newNoteButton: some View {
        Button {
            Task { await model.newNote() }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .disabled(model.scope == .trash && model.folders.isEmpty)
    }

    private var viewMenu: some View {
        Menu {
            Picker("View", selection: $model.gallery) {
                Label("View as List", systemImage: "list.bullet").tag(false)
                Label("View as Gallery", systemImage: "square.grid.2x2").tag(true)
            }
            Picker("Sort By", selection: $model.sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            if model.scope == .trash, !model.snapshot.trash.isEmpty {
                Divider()
                Button("Delete All", role: .destructive) { Task { await model.emptyTrash() } }
            }
        } label: {
            Label("View Options", systemImage: "ellipsis.circle")
        }
    }

    private var list: some View {
        List(selection: $model.selected) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.notes) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .draggable(note.id)
                            .contextMenu { menu(for: note) }
                            .swipeActions(edge: .leading) {
                                if note.trashed == nil {
                                    Button { Task { await model.setPinned(note.id, !note.pinned) } } label: {
                                        Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash.fill" : "pin.fill")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await model.delete(note.id) } } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if note.trashed == nil {
                                    Button { moving = note.id } label: { Label("Move", systemImage: "folder") }
                                        .tint(.indigo)
                                }
                            }
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.sections) { section in
                    if !section.title.isEmpty {
                        Text(section.title).font(.headline).padding(.horizontal)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)], spacing: 14) {
                        ForEach(section.notes) { note in
                            NoteTile(note: note, selected: model.selected == note.id)
                                .onTapGesture { model.selected = note.id }
                                .draggable(note.id)
                                .contextMenu { menu(for: note) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func menu(for note: NoteRecord) -> some View {
        if note.trashed != nil {
            Button("Recover") { Task { await model.restore(note.id) } }
            Button("Delete Permanently", role: .destructive) { Task { await model.delete(note.id) } }
        } else {
            Button(note.pinned ? "Unpin Note" : "Pin Note") { Task { await model.setPinned(note.id, !note.pinned) } }
            Button("Move…") { moving = note.id }
            Button("Duplicate") { Task { await model.duplicate(note.id) } }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.delete(note.id) } }
        }
    }
}

struct IdBox: Identifiable {
    var id: String
}

struct NoteRow: View {
    @EnvironmentObject private var model: NotesModel
    let note: NoteRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    highlighted(note.title).font(.headline).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(shortDate(note.modified)).font(.subheadline).foregroundStyle(.primary.opacity(0.8))
                    highlighted(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.scope == .all || model.scope == .trash {
                    Label(note.folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 0)
            if let image = note.summary.image {
                Thumbnail(url: model.resolve(image, in: note)).frame(width: 44, height: 44)
            }
        }
        .padding(.vertical, 3)
    }

    private var preview: String {
        let words = NoteSearch.words(model.search)
        let text = note.summary.preview
        if !words.isEmpty, let snippet = NoteSearch.snippet(text, words), !NoteSearch.matches(firstLine(text), words) {
            return snippet.replacingOccurrences(of: "\n", with: " ")
        }
        return text.isEmpty ? "No additional text" : firstLine(text)
    }

    private func firstLine(_ text: String) -> String {
        text.components(separatedBy: "\n").first ?? ""
    }

    private func highlighted(_ text: String) -> Text {
        let words = NoteSearch.words(model.search)
        guard !words.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        let utf16 = Array(text.utf16)
        for hit in NoteSearch.hits(text, words) where hit.upperBound <= utf16.count {
            let start = String.Index(utf16Offset: hit.lowerBound, in: text)
            let end = String.Index(utf16Offset: hit.upperBound, in: text)
            guard let lower = AttributedString.Index(start, within: attributed),
                  let upper = AttributedString.Index(end, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
        }
        return Text(attributed)
    }
}

func shortDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .numeric, time: .omitted)
}

struct NoteTile: View {
    @EnvironmentObject private var model: NotesModel
    let note: NoteRecord
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                if let image = note.summary.image {
                    Thumbnail(url: model.resolve(image, in: note)).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(note.summary.preview)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.yellow : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
            .aspectRatio(0.9, contentMode: .fit)
            Text(note.title).font(.subheadline.bold()).lineLimit(1)
            Text(shortDate(note.modified)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The first picture of a note, small.
struct Thumbnail: View {
    let url: URL?
    @State private var image: Image?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { image.resizable().scaledToFill() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await load() }
    }

    private func load() async -> Image? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) { () -> Image? in
            #if os(macOS)
            guard let picture = NSImage(contentsOf: url) else { return nil }
            return Image(nsImage: picture)
            #else
            guard let picture = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 240)) else { return nil }
            return Image(uiImage: picture)
            #endif
        }.value
    }
}

/// Into which folder a note goes.
struct MoveSheet: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    let noteId: String
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.folders) { folder in
                    Button {
                        Task { await model.move(noteId, to: folder.name) }
                        dismiss()
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            if model.note(noteId)?.folder == folder.name { Image(systemName: "checkmark") }
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("New Folder", text: $newName)
                        Button("Move") {
                            let name = newName
                            Task {
                                await model.createFolder(name)
                                await model.move(noteId, to: name)
                            }
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Move to Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}
