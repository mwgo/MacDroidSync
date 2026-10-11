import NotesMDEditor
import NotesMDKit
import SwiftUI

@main
struct NotesMDApp: App {
    @StateObject private var model = NotesModel()
    @StateObject private var editor = EditorController()
    #if os(macOS)
    /// Light, dark, or as the system is; the whole app, menus and windows alike.
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(editor)
                #if os(macOS)
                .onAppear { Appearance(rawValue: appearance)?.apply() }
                .onChange(of: appearance) { _, value in Appearance(rawValue: value)?.apply() }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
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
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
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

#if os(macOS)
import AppKit

/// How the app looks: as the system does, or always light or dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Use System Appearance"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
#endif
