import Combine
#if os(macOS)
import AppKit
#endif
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
    // How the list looks, kept between launches.
    @Published var sort = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .modified {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    @Published var gallery = UserDefaults.standard.bool(forKey: "gallery") {
        didSet { UserDefaults.standard.set(gallery, forKey: "gallery") }
    }
    /// All notes in one list grouped by folder, as on the phone, rather than by
    /// date. The list then holds the folders itself and always shows every note.
    @Published var byFolder = UserDefaults.standard.object(forKey: "byFolder") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(byFolder, forKey: "byFolder")
            if byFolder { scope = .all }
        }
    }
    @Published private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(collapsed.sorted(), forKey: "collapsed") }
    }

    // MARK: - Folded groups

    /// Whether a group shows only its header; never while searching, so that every hit shows.
    func isCollapsed(_ section: NoteSection) -> Bool {
        if dragging { return !section.title.isEmpty }
        return search.isEmpty && collapsed.contains(section.id)
    }

    /// A note is being dragged: every group shows only its header, so that
    /// each one is in reach; how the groups were folded stays as it was.
    @Published private(set) var dragging = false

    func beginDrag() {
        dragId += 1
        let session = dragId
        hovering = false
        hoverPlaces = []
        dragStarted = Date()
        // Some time for the note to reach the list before being away from it counts.
        hoverChanged = Date().addingTimeInterval(1.5)
        // A moment after the drag has lifted the note, not under its feet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.dragId == session else { return }
            withAnimation(.snappy) { self.dragging = true }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watch(session) }
        }
    }

    func endDrag() {
        dragId += 1
        watchdog?.invalidate()
        watchdog = nil
        hovering = false
        hoverPlaces = []
        guard dragging else { return }
        withAnimation(.snappy) { dragging = false }
    }

    private var dragId = 0
    private var watchdog: Timer?
    /// Whether the dragged note is over the list, and since when it is or is not.
    private var hovering = false
    private var hoverChanged = Date()
    private var dragStarted = Date()

    /// Where a drag is: over the list or one of its groups, over the folders, or elsewhere.
    func dragHover(_ over: Bool, in place: String = "list") {
        if over { hoverPlaces.insert(place) } else { hoverPlaces.remove(place) }
        guard hoverPlaces.isEmpty == hovering else { return }
        hovering = !hoverPlaces.isEmpty
        hoverChanged = Date()
    }
    private var hoverPlaces: Set<String> = []

    /// The system does not always say a drag has ended - dropped where nothing
    /// takes it, or given up - so the end is also read off what is seen: on the
    /// Mac the mouse button let go, anywhere the note away from the list for a while.
    private func watch(_ session: Int) {
        guard session == dragId else { return }
        #if os(macOS)
        if NSEvent.pressedMouseButtons & 1 == 0, Date().timeIntervalSince(dragStarted) > 0.3 {
            endDrag()
            return
        }
        #endif
        if !hovering, Date().timeIntervalSince(hoverChanged) > 1.2 { endDrag() }
    }

    /// What a dragged note carries: its id, and a token that ends the drag
    /// when the system lets go of it, dropped anywhere or not at all.
    func dragItem(_ id: String) -> NSItemProvider {
        beginDrag()
        let provider = NSItemProvider(object: id as NSString)
        let session = dragId
        let token = DragToken { [weak self] in
            guard let self, self.dragId == session else { return }
            self.endDrag()
        }
        objc_setAssociatedObject(provider, &DragToken.key, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return provider
    }

    func toggleCollapsed(_ section: NoteSection) {
        // A drag the system never said had ended: a tap on a group lets the groups go.
        if dragging {
            endDrag()
            return
        }
        if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
    }

    /// Unfolds a group for good: the one a note was just dropped into, to show it there.
    func expand(_ id: String) {
        collapsed.remove(id)
    }

    /// Whether every group shown is folded.
    var allCollapsed: Bool {
        let ids = sections.filter { !$0.title.isEmpty }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy(collapsed.contains)
    }

    /// Folds every group shown, or unfolds them all when they all are folded.
    func toggleAllCollapsed() {
        let ids = sections.filter { !$0.title.isEmpty }.map(\.id)
        if allCollapsed { collapsed.subtract(ids) } else { collapsed.formUnion(ids) }
    }

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
        case .trash: return "Deleted"
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
        return sorted(found(notes))
    }

    /// Of [notes], those with every word searched for.
    private func found(_ notes: [NoteRecord]) -> [NoteRecord] {
        let words = NoteSearch.words(search)
        guard !words.isEmpty else { return notes }
        return notes.filter { NoteSearch.matches($0.summary.title + "\n" + $0.summary.preview, words) || fullTextMatches($0, words) }
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
        if byFolder, scope == .all || scope == nil {
            // Every folder in its order, as the phone shows them.
            for folder in snapshot.folders {
                let inside = rest.filter { $0.folder == folder.name }
                if !inside.isEmpty || search.isEmpty {
                    sections.append(NoteSection(id: "folder:" + folder.name, title: folder.name, notes: inside))
                }
            }
            // The deleted notes last, as on the phone, and somewhere to drop a note to delete it.
            let deleted = found(snapshot.trash).sorted { ($0.trashed ?? .distantPast) > ($1.trashed ?? .distantPast) }
            if !deleted.isEmpty || search.isEmpty {
                sections.append(NoteSection(id: "deleted", title: "Deleted", notes: deleted))
            }
            return sections
        }
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
        if let made = await run({ try await $0.createFolder(name) }), !byFolder { scope = .folder(made) }
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

/// Ends a drag once the item that carries it is let go of.
final class DragToken: NSObject {
    nonisolated(unsafe) static var key = 0
    private let onEnd: @MainActor () -> Void

    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
    }

    deinit {
        let onEnd = onEnd
        DispatchQueue.main.async { MainActor.assumeIsolated { onEnd() } }
    }
}
