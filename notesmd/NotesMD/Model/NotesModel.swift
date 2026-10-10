import Combine
import Foundation
import NotesMDKit
import SwiftUI

/// Where the list looks: every note, one folder, or the trash.
enum Scope: Hashable {
    case all
    case folder(String)
    case trash
}

enum SortOrder: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }

    var label: String {
        switch self {
        case .modified: return "Date Edited"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }
}

/// One group of the notes list.
struct NoteSection: Identifiable {
    var id: String
    var title: String
    var notes: [NoteRecord]
}

/// The notes of the chosen folder as the screens see them, and every change
/// they make, through one `FolderStore`.
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var snapshot = NotesSnapshot()
    @Published var scope: Scope? = .all
    @Published var selected: String?
    @Published var search = ""
    @Published var error: String?
    @AppStorage("sort") var sort: SortOrder = .modified
    @AppStorage("gallery") var gallery = false

    private(set) var store: FolderStore?
    private var monitor: FolderMonitor?

    init() {
        if let url = FolderAccess.restore() { open(url) }
    }

    // MARK: - The folder

    func open(_ url: URL) {
        monitor?.stop()
        FolderAccess.remember(url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url
        let store = FolderStore(root: url, writer: FolderAccess.writer)
        self.store = store
        monitor = FolderMonitor(root: url, interval: 8) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        Task {
            await refresh()
            if snapshot.folders.isEmpty { _ = try? await store.createFolder("Notes") }
            try? await store.purgeTrash()
            await refresh()
        }
    }

    func forgetFolder() {
        monitor?.stop()
        monitor = nil
        store = nil
        root = nil
        snapshot = NotesSnapshot()
        FolderAccess.forget()
    }

    func refresh() async {
        guard let store else { return }
        do {
            let next = try await store.scan()
            if next != snapshot { snapshot = next }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - What the list shows

    var folders: [FolderRecord] { snapshot.folders }

    func count(in folder: String) -> Int { snapshot.notes.filter { $0.folder == folder }.count }

    var scopeTitle: String {
        switch scope {
        case .folder(let name): return name
        case .trash: return "Recently Deleted"
        default: return "All Notes"
        }
    }

    /// The folder a new note goes into: the one shown, or the first.
    var currentFolder: String {
        if case .folder(let name) = scope { return name }
        return snapshot.folders.first?.name ?? "Notes"
    }

    var visible: [NoteRecord] {
        var notes: [NoteRecord]
        switch scope {
        case .trash: notes = snapshot.trash
        case .folder(let name): notes = snapshot.notes.filter { $0.folder == name }
        default: notes = snapshot.notes
        }
        let words = NoteSearch.words(search)
        if !words.isEmpty {
            notes = notes.filter { NoteSearch.matches($0.summary.title + "\n" + $0.summary.preview, words) || fullTextMatches($0, words) }
        }
        return sorted(notes)
    }

    private var fullText: [String: (sha: String, text: String)] = [:]

    /// The whole text of a note, for a search the preview alone does not answer.
    private func fullTextMatches(_ note: NoteRecord, _ words: [[UInt16]]) -> Bool {
        if let cached = fullText[note.id], cached.sha == note.sha { return NoteSearch.matches(cached.text, words) }
        guard let store else { return false }
        let url = store.url(of: note.path)
        guard let data = try? Data(contentsOf: url) else { return false }
        let text = NoteSummary.text(String(decoding: data, as: UTF8.self))
        fullText[note.id] = (note.sha, text)
        return NoteSearch.matches(text, words)
    }

    func sorted(_ notes: [NoteRecord]) -> [NoteRecord] {
        switch sort {
        case .modified: return notes.sorted { $0.modified > $1.modified }
        case .created: return notes.sorted { $0.created > $1.created }
        case .title: return notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Pinned first, then by when they were edited, as Notes groups them.
    var sections: [NoteSection] {
        let notes = visible
        guard scope != .trash else { return notes.isEmpty ? [] : [NoteSection(id: "trash", title: "", notes: notes)] }
        var sections: [NoteSection] = []
        let pinned = notes.filter(\.pinned)
        if !pinned.isEmpty { sections.append(NoteSection(id: "pinned", title: "Pinned", notes: pinned)) }
        let rest = notes.filter { !$0.pinned }
        guard sort != .title else {
            if !rest.isEmpty { sections.append(NoteSection(id: "notes", title: pinned.isEmpty ? "" : "Notes", notes: rest)) }
            return sections
        }
        let calendar = Calendar.current
        let now = Date()
        var groups: [(String, [NoteRecord])] = []
        for note in rest {
            let date = sort == .created ? note.created : note.modified
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
                title = "Previous 7 Days"
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 30 {
                title = "Previous 30 Days"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                title = date.formatted(.dateTime.month(.wide))
            } else {
                title = date.formatted(.dateTime.year())
            }
            if groups.last?.0 == title {
                groups[groups.count - 1].1.append(note)
            } else {
                groups.append((title, [note]))
            }
        }
        sections += groups.map { NoteSection(id: $0.0, title: $0.0, notes: $0.1) }
        return sections
    }

    func note(_ id: String?) -> NoteRecord? {
        guard let id else { return nil }
        return snapshot.note(snapshot.merged[id] ?? id)
    }

    func url(of note: NoteRecord) -> URL? { store?.url(of: note.path) }

    func resolve(_ link: String, in note: NoteRecord) -> URL? { store?.resolve(link: link, of: note) }

    // MARK: - Changes

    private func run<T>(_ action: (FolderStore) async throws -> T) async -> T? {
        guard let store else { return nil }
        do {
            let result = try await action(store)
            snapshot = await store.current()
            return result
        } catch {
            self.error = error.localizedDescription
            snapshot = await store.current()
            return nil
        }
    }

    func read(_ id: String) async -> String? {
        await run { try await $0.read(id) }
    }

    @discardableResult
    func newNote(in folder: String? = nil) async -> NoteRecord? {
        let into = folder ?? currentFolder
        guard let note = await run({ try await $0.create(folder: into, markdown: "# ") }) else { return nil }
        if scope == .trash { scope = .folder(into) }
        selected = note.id
        return note
    }

    /// Writes a note's text over the version it was read at. When the file
    /// changed meanwhile, that version is kept as a note of its own first.
    func save(_ id: String, markdown: String, baseSHA: String?, rename: Bool) async -> NoteRecord? {
        guard let store else { return nil }
        do {
            let note = try await store.write(id, markdown: markdown, baseSHA: baseSHA, rename: rename)
            snapshot = await store.current()
            return note
        } catch FolderStoreError.changed {
            let stamp = Date().formatted(.dateTime.hour().minute())
            _ = try? await store.duplicate(id, titleSuffix: " (conflict \(stamp))")
            let note = try? await store.write(id, markdown: markdown, rename: rename)
            snapshot = await store.current()
            return note
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) async { await run { try await $0.setPinned(id, pinned) } }

    func move(_ id: String, to folder: String) async { await run { try await $0.move(id, to: folder) } }

    func duplicate(_ id: String) async {
        if let copy = await run({ try await $0.duplicate(id) }) { selected = copy.id }
    }

    func delete(_ id: String) async {
        if selected == id { selected = nil }
        if snapshot.trash.contains(where: { $0.id == id }) {
            await run { try await $0.deleteForever(id) }
        } else {
            await run { try await $0.trash(id) }
        }
    }

    func restore(_ id: String) async { await run { try await $0.restore(id) } }

    /// A note left with nothing in it is not kept.
    func discardIfBlank(_ id: String, markdown: String) async {
        guard Markdown.isBlank(markdown) else { return }
        await run { try await $0.deleteForever(id) }
    }

    func emptyTrash() async {
        for note in snapshot.trash { await run { try await $0.deleteForever(note.id) } }
    }

    func createFolder(_ name: String) async {
        if let made = await run({ try await $0.createFolder(name) }) { scope = .folder(made) }
    }

    func renameFolder(_ from: String, to: String) async {
        await run { try await $0.renameFolder(from, to: to) }
        if scope == .folder(from) { scope = .folder(FileNames.folderName(to)) }
    }

    func deleteFolder(_ name: String) async {
        guard snapshot.folders.count > 1 else {
            error = FolderStoreError.lastFolder.localizedDescription
            return
        }
        await run { try await $0.deleteFolder(name) }
        if scope == .folder(name) { scope = .all }
    }

    func moveFolders(from source: IndexSet, to destination: Int) async {
        var names = snapshot.folders.map(\.name)
        names.move(fromOffsets: source, toOffset: destination)
        await run { try await $0.reorderFolders(names) }
    }

    // MARK: - Attachments

    /// Keeps a file in the note's attachments folder; returns the Markdown line that shows it.
    func attach(_ url: URL, to id: String, asFile: Bool, drawing: Bool = false) async -> String? {
        let name = url.lastPathComponent
        guard let link = await run({ try await $0.addAsset(to: id, from: url, name: asFile ? name : nil) }) else { return nil }
        if asFile { return Markdown.fileToMarkdown(MdFile(path: link, name: name)) }
        return Markdown.imageToMarkdown(MdImage(path: link, alt: drawing ? MdImage.drawingAlt : ""))
    }

    func writeAsset(of id: String, inner: String, data: Data) async {
        await run { try await $0.writeAsset(of: id, inner: inner, data: data) }
    }
}
