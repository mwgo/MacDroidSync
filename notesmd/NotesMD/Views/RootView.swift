import NotesMDKit
import SwiftUI
import UniformTypeIdentifiers

/// The folder of notes first, then the notes.
struct RootView: View {
    @EnvironmentObject private var model: NotesModel

    var body: some View {
        Group {
            if model.root == nil {
                WelcomeView()
            } else {
                ContentView()
            }
        }
        .alert("Notes MD", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// Asks once where the notes are: a folder on iCloud Drive that the Mac, iPad
/// and iPhone share, and that MacDroidSync keeps the same as the phone.
struct WelcomeView: View {
    @EnvironmentObject private var model: NotesModel
    @State private var choosing = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Color.accentColor)
            Text("Notes MD")
                .font(.largeTitle.bold())
            Text("Your notes are Markdown files in a folder on iCloud Drive, one folder per notebook. Choose the same folder on your Mac, iPad and iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            #if os(macOS)
            Button {
                model.open(FolderAccess.iCloudFolder)
            } label: {
                Label("Use iCloud Drive › Notes MD", systemImage: "icloud")
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            #endif
            Button {
                choosing = true
            } label: {
                Label("Choose a Folder…", systemImage: "folder")
                    .frame(minWidth: 260)
            }
            #if os(iOS)
            .buttonStyle(.borderedProminent)
            #endif
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            model.open(url)
        }
    }
}
