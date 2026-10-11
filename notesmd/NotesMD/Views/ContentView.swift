import NotesMDKit
import SwiftUI

/// Folders, the notes of one, and the note itself, as in Notes. On iPhone the
/// three collapse into one stack.
struct ContentView: View {
    @EnvironmentObject private var model: NotesModel
    /// Whether the folders show, as they were left.
    @State private var visibility = ContentView.savedVisibility
    /// Until the window has been laid out the split view sets its columns
    /// itself; only what is changed after that is the user's and kept.
    @State private var restored = false
    @State private var newFolder = false
    @State private var folderName = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(newFolder: $newFolder)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            if let id = model.selected, model.note(id) != nil {
                NoteDetailView(noteId: id)
                    .id(id)
            } else {
                Text(model.visible.isEmpty ? "No Notes" : "No Note Selected")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                    .toolbar {
                        // On iPad the note's bar is where a new note is made, even with no note open.
                        if isPad {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { Task { await model.newNote() } } label: { Label("New Note", systemImage: "square.and.pencil") }
                                    .disabled(model.scope == .trash && model.folders.isEmpty)
                            }
                        }
                    }
                    #endif
            }
        }
        .onChange(of: visibility) { _, value in
            if restored { ContentView.save(value) }
        }
        .onAppear {
            let saved = ContentView.savedVisibility
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                visibility = saved
                restored = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in newFolder = true }
        .onChange(of: model.scope) { _, _ in
            // Another folder: the note open stays only if it is in it.
            if let id = model.selected, !model.visible.contains(where: { $0.id == id }) { model.selected = nil }
        }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Save") {
                let name = folderName
                folderName = ""
                Task { await model.createFolder(name) }
            }
        } message: {
            Text("Enter a name for this folder.")
        }
        #if os(macOS)
        .sheet(isPresented: $importing) { AppleNotesSheet(mode: .importing) }
        .sheet(isPresented: $exporting) { AppleNotesSheet(mode: .exporting) }
        .onReceive(NotificationCenter.default.publisher(for: .importFromNotes)) { _ in importing = true }
        .onReceive(NotificationCenter.default.publisher(for: .exportToNotes)) { _ in exporting = true }
        #endif
    }

    #if os(macOS)
    @State private var importing = false
    @State private var exporting = false
    #endif
}

struct SidebarView: View {
    @EnvironmentObject private var model: NotesModel
    @Binding var newFolder: Bool
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        List(selection: $model.scope) {
            Section {
                Label {
                    HStack {
                        Text("All Notes")
                        Spacer()
                        Text("\(model.snapshot.notes.count)").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "tray.full")
                }
                .tag(Scope.all)
            }
            Section("Folders") {
                ForEach(model.folders) { folder in
                    Label {
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Text("\(model.count(in: folder.name))").foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(Scope.folder(folder.name))
                    .dropDestination(for: String.self) { ids, _ in
                        model.endDrag()
                        model.expand("folder:" + folder.name)
                        for id in ids { Task { await model.move(id, to: folder.name) } }
                        return !ids.isEmpty
                    } isTargeted: { model.dragHover($0, in: "folder:" + folder.name) }
                    .contextMenu {
                        Button("Rename Folder") {
                            newName = folder.name
                            renaming = folder.name
                        }
                        Button("Delete Folder", role: .destructive) { deleting = folder.name }
                            .disabled(model.folders.count < 2)
                    }
                }
                .onMove { source, destination in
                    Task { await model.moveFolders(from: source, to: destination) }
                }
            }
            Section {
                Label {
                    HStack {
                        Text("Deleted")
                        Spacer()
                        Text("\(model.snapshot.trash.count)").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "trash")
                }
                .tag(Scope.trash)
                .dropDestination(for: String.self) { ids, _ in
                    model.endDrag()
                    let live = ids.filter { id in !model.snapshot.trash.contains { $0.id == id } }
                    for id in live { Task { await model.delete(id) } }
                    return !live.isEmpty
                } isTargeted: { model.dragHover($0, in: "trash") }
            }
        }
        // Between the folders a drag is still under way, not wandered off.
        .onDrop(of: [.plainText], isTargeted: Binding(get: { false }, set: { model.dragHover($0, in: "sidebar") })) { _ in
            model.endDrag()
            return false
        }
        .navigationTitle("Folders")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { newFolder = true } label: { Image(systemName: "folder.badge.plus") }
            }
            if !isPad {
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button { Task { await model.newNote() } } label: { Image(systemName: "square.and.pencil") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { newFolder = true } label: { Label("New Folder", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
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
    }
}

extension ContentView {
    private static let visibilityKey = "columns"

    static var savedVisibility: NavigationSplitViewVisibility {
        switch UserDefaults.standard.string(forKey: visibilityKey) {
        case "doubleColumn": return .doubleColumn
        case "detailOnly": return .detailOnly
        default: return .all
        }
    }

    static func save(_ visibility: NavigationSplitViewVisibility) {
        let value: String
        switch visibility {
        case .doubleColumn: value = "doubleColumn"
        case .detailOnly: value = "detailOnly"
        default: value = "all"
        }
        UserDefaults.standard.set(value, forKey: visibilityKey)
    }
}
