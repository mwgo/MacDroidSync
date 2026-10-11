import ImageIO
import NotesMDKit
import SwiftUI

/// The notes of the folder shown, as a list or as a gallery.
struct NoteListView: View {
    @EnvironmentObject private var model: NotesModel
    @State private var moving: String?
    /// A folder being renamed or deleted from its group's menu.
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    /// The group a dragged note is over.
    @State private var dropTarget: String?
    /// Whether a dragged note is anywhere over the list, or over one of its groups.
    @State private var listTargeted = false
    @State private var hoveredGroup: String?

    var body: some View {
        Group {
            if model.gallery {
                gallery
            } else {
                list
            }
        }
        // The whole list hears a drag pass over it, so that one let go of
        // elsewhere, or given up, is known to have ended.
        .onDrop(of: [.plainText], isTargeted: $listTargeted) { _ in
            model.endDrag()
            return false
        }
        .onChange(of: listTargeted) { _, over in model.dragHover(over || hoveredGroup != nil) }
        .navigationTitle(model.scopeTitle)
        #if os(iOS)
        .searchable(text: $model.search, prompt: "Search")
        #endif
        .overlay {
            if model.visible.isEmpty {
                Text(model.search.isEmpty ? (model.scope == .trash ? "No Deleted Notes" : "No Notes") : "No Results")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { foldAllButton }
            ToolbarItem(placement: .topBarTrailing) { viewMenu }
            // On iPad a new note is made from the note's own bar; on iPhone from here.
            if !isPad {
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) { newNoteButton }
            }
            #else
            // Over the list, where its folders are; a new note at the start of the note's bar, as in Notes.
            // With the list as the window's first column, its own items stand over it already.
            if model.byFolder {
                // A new note then starts the note's bar, from the window's second column.
                ToolbarItemGroup {
                    foldAllButton
                    viewMenu
                }
            } else {
                ToolbarItemGroup(placement: .navigation) {
                    foldAllButton
                    viewMenu
                }
                ToolbarItem { newNoteButton }
            }
            #endif
        }
        #if os(macOS)
        .modifier(NoToolbarTitle())
        #endif
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let from = renaming {
                    let to = newName
                    Task { await model.renameFolder(from, to: to) }
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete Folder?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let name = deleting { Task { await model.deleteFolder(name) } }
                deleting = nil
            }
        } message: {
            Text("The notes in it are moved to Deleted.")
        }
        .sheet(item: Binding(get: { moving.map(IdBox.init) }, set: { moving = $0?.id })) { box in
            MoveSheet(noteId: box.id)
        }
    }

    /// Folds every group, or unfolds them all.
    private var foldAllButton: some View {
        Button {
            withAnimation(.snappy) { model.toggleAllCollapsed() }
        } label: {
            Label(model.allCollapsed ? "Expand All Groups" : "Collapse All Groups",
                  systemImage: model.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
        }
        .help(model.allCollapsed ? "Expand All Groups" : "Collapse All Groups")
        .disabled(model.sections.allSatisfy { $0.title.isEmpty })
    }

    /// A group's header, drawn as its folder is in the sidebar - the same icon,
    /// name and count - with a chevron; a tap folds or unfolds it.
    private func header(_ section: NoteSection) -> some View {
        Button {
            withAnimation(.snappy) { model.toggleCollapsed(section) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.isCollapsed(section) ? 0 : 90))
                    .frame(width: 12)
                Label {
                    Text(section.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: icon(of: section)).foregroundStyle(Color.accentColor)
                }
                .font(.body)
                Spacer()
                Text("\(section.notes.count)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    // MARK: - Dragging notes between groups

    /// Whether notes can be dropped on a group: a folder, or the pinned ones.
    private func accepts(_ section: NoteSection) -> Bool {
        section.id == "pinned" || section.id == "deleted" || section.id.hasPrefix("folder:")
    }

    /// A header that takes dropped notes, lit while one is over it.
    private func droppableHeader(_ section: NoteSection) -> some View {
        header(section)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(dropTarget == section.id ? 0.25 : 0))
            )
            .dropDestination(for: String.self) { ids, _ in drop(ids, on: section) } isTargeted: { target(section, $0) }
            .contextMenu { folderMenu(section) }
    }

    /// A folder's own commands, from its group's header, now that no panel of folders shows them.
    @ViewBuilder
    private func folderMenu(_ section: NoteSection) -> some View {
        if section.id.hasPrefix("folder:") {
            let name = String(section.id.dropFirst("folder:".count))
            Button("New Note") { Task { await model.newNote(in: name) } }
            Divider()
            Button("Rename Folder") {
                newName = name
                renaming = name
            }
            Button("Delete Folder", role: .destructive) { deleting = name }
                .disabled(model.folders.count < 2)
        } else if section.id == "deleted", !model.snapshot.trash.isEmpty {
            Button("Delete All", role: .destructive) { Task { await model.emptyTrash() } }
        }
    }

    private func target(_ section: NoteSection, _ over: Bool) {
        if over {
            hoveredGroup = section.id
        } else if hoveredGroup == section.id {
            hoveredGroup = nil
        }
        model.dragHover(listTargeted || hoveredGroup != nil)
        guard accepts(section) else { return }
        if over {
            dropTarget = section.id
        } else if dropTarget == section.id {
            dropTarget = nil
        }
    }

    /// Notes dropped on a group: on a folder they move there and are no longer
    /// pinned, as on the phone; on the pinned group they are pinned; on the
    /// deleted notes they are deleted.
    private func drop(_ ids: [String], on section: NoteSection) -> Bool {
        dropTarget = nil
        hoveredGroup = nil
        model.endDrag()
        // The group the note went into opens, to show it there.
        if accepts(section) { model.expand(section.id) }
        guard accepts(section) else { return false }
        let notes = ids.compactMap { model.note($0) }.filter { $0.trashed == nil }
        guard !notes.isEmpty else { return false }
        Task {
            for note in notes {
                if section.id == "pinned" {
                    if !note.pinned { await model.setPinned(note.id, true) }
                    continue
                }
                if section.id == "deleted" {
                    await model.delete(note.id)
                    continue
                }
                let folder = String(section.id.dropFirst("folder:".count))
                if note.pinned { await model.setPinned(note.id, false) }
                if note.folder != folder { await model.move(note.id, to: folder) }
            }
        }
        return true
    }

    /// The icon a group has in the sidebar.
    private func icon(of section: NoteSection) -> String {
        if section.id == "pinned" { return "pin" }
        if section.id == "deleted" { return "trash" }
        if section.id.hasPrefix("folder:") { return "folder" }
        return "calendar"
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
            // From any folder: grouping by folders shows them all, each a group.
            Picker("Group By", selection: $model.byFolder) {
                Label("Folders", systemImage: "folder").tag(true)
                Label("Date", systemImage: "calendar").tag(false)
            }
            Picker("Sort By", selection: $model.sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            if model.byFolder {
                Divider()
                Button { NotificationCenter.default.post(name: .newFolder, object: nil) } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
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
                    ForEach(model.isCollapsed(section) ? [] : section.notes) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .dropDestination(for: String.self) { ids, _ in drop(ids, on: section) } isTargeted: { target(section, $0) }
                            .onDrag { model.dragItem(note.id) }
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
                    if !section.title.isEmpty { droppableHeader(section) }
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
                        droppableHeader(section).padding(.horizontal)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 108), spacing: 10)], spacing: 12) {
                        ForEach(model.isCollapsed(section) ? [] : section.notes) { note in
                            NoteTile(note: note, selected: model.selected == note.id)
                                .dropDestination(for: String.self) { ids, _ in drop(ids, on: section) } isTargeted: { target(section, $0) }
                                .onTapGesture { model.selected = note.id }
                                .onDrag { model.dragItem(note.id) }
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    highlighted(note.title).font(.headline).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(shortDate(note.modified)).font(.subheadline).foregroundStyle(.primary.opacity(0.8))
                    highlighted(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if (model.scope == .all && !model.byFolder) || model.scope == .trash {
                    Label(note.folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 0)
            if let image = note.summary.image {
                Thumbnail(url: model.resolve(image, in: note), corner: 5).frame(width: 36, height: 36)
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
        VStack(spacing: 4) {
            card
                .aspectRatio(0.82, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 2.5 : 0.5)
                )
            Text(shortDate(note.modified)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// The note as a small page: its title on top, under it its first picture
    /// filling the rest, or the start of its text.
    private var card: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.background)
            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let image = note.summary.image {
                        Thumbnail(url: model.resolve(image, in: note), corner: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(note.summary.preview)
                            .font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The first picture of a note, small, filling its frame and cut to it.
struct Thumbnail: View {
    let url: URL?
    var corner: CGFloat = 6
    @State private var image: Image?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image { image.resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .task(id: url) { image = await load() }
    }

    /// A small copy, read off the main thread; a large photo is never decoded whole.
    private func load() async -> Image? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) { () -> Image? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return Image(decorative: picture, scale: 1)
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

#if os(macOS)
/// The folder's name stays the window's title, not text in the toolbar,
/// which leaves the room over the list to its buttons.
private struct NoToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
#endif
