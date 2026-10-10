#if os(macOS)
import AppleNotesBridge
import NotesMDKit
import SwiftUI

/// Import from and export to Notes on this Mac: an account, the folders, and
/// a copy of each note not already there.
struct AppleNotesSheet: View {
    enum Mode { case importing, exporting }
    let mode: Mode

    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [AppleNotesLibrary.Account] = []
    @State private var account: String?
    @State private var folders: [String] = []
    @State private var chosen: Set<String> = []
    @State private var status = ""
    @State private var running = false
    @State private var done: AppleNotesTransfer.Result?
    @State private var transfer: AppleNotesTransfer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .importing ? "Import from Notes" : "Export to Notes").font(.title2.bold())
            Text(mode == .importing
                 ? "Copies the notes of the chosen folders of Notes into this folder of notes, pictures and files included. A note already here with the same words is left out."
                 : "Copies the notes of the chosen folders into Notes, into folders of the same names. A note already there with the same words is left out.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !accounts.isEmpty {
                Picker("Account", selection: $account) {
                    ForEach(accounts, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
                .onChange(of: account) { _, _ in Task { await loadFolders() } }
            }
            List(folders, id: \.self) { folder in
                Toggle(folder, isOn: Binding(get: { chosen.contains(folder) }, set: { if $0 { chosen.insert(folder) } else { chosen.remove(folder) } }))
            }
            .frame(minHeight: 180)
            if let done {
                Text("Copied \(done.copied), already there \(done.skipped)" + (done.failed.isEmpty ? "." : ", failed \(done.failed.count): " + done.failed.joined(separator: "; ")))
                    .foregroundStyle(done.failed.isEmpty ? Color.secondary : Color.red)
            } else {
                Text(status).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button(chosen.count == folders.count ? "Select None" : "Select All") {
                    chosen = chosen.count == folders.count ? [] : Set(folders)
                }
                .disabled(folders.isEmpty || running)
                Spacer()
                Button("Close") { dismiss() }
                Button(mode == .importing ? "Import" : "Export") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || running)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .task { await start() }
    }

    private func start() async {
        guard let store = model.store else { return }
        let transfer = AppleNotesTransfer(store: store)
        self.transfer = transfer
        if mode == .exporting {
            folders = model.folders.map(\.name)
        }
        status = "Asking Notes for its accounts…"
        do {
            accounts = try await transfer.accounts()
            account = accounts.first { $0.name == "iCloud" }?.name ?? accounts.first?.name
            if mode == .importing { await loadFolders() }
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    private func loadFolders() async {
        guard mode == .importing, let transfer else { return }
        do {
            folders = try await transfer.appleFolders(account: account).sorted()
            chosen = []
        } catch {
            status = error.localizedDescription
        }
    }

    private func run() async {
        guard let transfer else { return }
        running = true
        done = nil
        defer { running = false }
        do {
            let report: (AppleNotesTransfer.Progress) -> Void = { progress in
                status = progress.title.isEmpty ? "" : "\(progress.done + 1) of \(progress.total): \(progress.title)"
            }
            if mode == .importing {
                done = try await transfer.importNotes(account: account, folders: chosen, progress: report)
            } else {
                done = try await transfer.exportNotes(account: account, folders: chosen, progress: report)
            }
            await model.refresh()
        } catch {
            status = error.localizedDescription
        }
    }
}
#endif
