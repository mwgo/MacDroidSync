import NotesMDEditor
import NotesMDKit
import SwiftUI

@main
struct NotesMDApp: App {
    @StateObject private var model = NotesModel()
    @StateObject private var editor = EditorController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(editor)
                .tint(.yellow)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { Task { await model.newNote() } }
                    .keyboardShortcut("n")
                    .disabled(model.store == nil)
                Button("New Folder…") { NotificationCenter.default.post(name: .newFolder, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.store == nil)
            }
            CommandMenu("Format") {
                Button("Title") { editor.cycleHeading() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Heading") { editor.toggleBlock(.heading) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Body") { editor.toggleBlock(.paragraph) }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Monospaced") { editor.toggleBlock(.code) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Bold") { editor.toggle(.bold) }.keyboardShortcut("b")
                Button("Italic") { editor.toggle(.italic) }.keyboardShortcut("i")
                Button("Underline") { editor.toggle(.underline) }.keyboardShortcut("u")
                Button("Code") { editor.toggle(.code) }.keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Bulleted List") { editor.toggleBlock(.bullet) }.keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Numbered List") { editor.toggleBlock(.numbered) }.keyboardShortcut("9", modifiers: [.command, .shift])
                Button("Checklist") { editor.toggleBlock(.checkbox) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Block Quote") { editor.toggleBlock(.quote) }.keyboardShortcut("'", modifiers: [.command])
                Divider()
                Button("Indent") { editor.indent() }.keyboardShortcut("]")
                Button("Outdent") { editor.outdent() }.keyboardShortcut("[")
            }
            CommandGroup(after: .importExport) {
                Button("Import from Notes…") { NotificationCenter.default.post(name: .importFromNotes, object: nil) }
                    .disabled(model.store == nil)
                Button("Export to Notes…") { NotificationCenter.default.post(name: .exportToNotes, object: nil) }
                    .disabled(model.store == nil)
                Divider()
                Button("Choose Notes Folder…") { model.forgetFolder() }
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let newFolder = Notification.Name("NotesMD.newFolder")
    static let importFromNotes = Notification.Name("NotesMD.importFromNotes")
    static let exportToNotes = Notification.Name("NotesMD.exportToNotes")
}
