import AppKit
import Foundation

/// A note read from Notes: its body, and its attachments saved to files.
public struct MacNoteContent {
    public struct Attachment: Codable, Equatable {
        public var id: String
        public var name: String?
        public var file: String
    }

    public var info: MacNoteInfo
    public var html: String
    public var attachments: [Attachment]
}

/// What the sync needs of Notes. `AppleNotesLibrary` is the real one; the
/// tests use one in memory.
public protocol NotesLibrary: AnyObject {
    func list() async throws -> [MacNoteInfo]
    func folders() async throws -> [String]
    /// The note's attachments are saved into `folder`.
    func read(id: String, into folder: URL) async throws -> MacNoteContent
    func create(folder: String, html: String, files: [URL]) async throws -> MacNoteInfo
    /// Replaces the body, which drops the old attachments, attaches `files`
    /// again, and moves the note into `folder` when it is elsewhere.
    func update(id: String, folder: String, html: String, files: [URL]) async throws -> MacNoteInfo
    /// Into another folder, the note itself untouched.
    func move(id: String, folder: String) async throws -> MacNoteInfo
    /// Into Recently Deleted, where Notes keeps it for thirty days.
    func delete(id: String) async throws
    func ensureFolder(_ name: String) async throws
}

public enum NotesLibraryError: LocalizedError, Equatable {
    /// macOS did not let this app control Notes; the user decides in System Settings.
    case notAuthorized
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "MacDroidSync may not control Notes. Allow it in System Settings → Privacy & Security → Automation."
        case .failed(let detail):
            return "Notes: \(detail)"
        }
    }
}

/// Notes through JavaScript for Automation, one `osascript` per call, its
/// answer as JSON on standard output. A process of its own rather than OSAKit
/// in this one: Notes can take its time, and a call stuck on it is killed
/// without taking the app along.
public final class AppleNotesLibrary: NotesLibrary {

    /// The account to sync. Nil picks iCloud, and the default account when
    /// there is no iCloud: an Exchange account in Notes holds no pictures,
    /// tables or attachments, so it is never the first choice.
    public var accountName: () -> String?
    private let scratch: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "pl.wojas.MacDroidSync.notes-bridge")

    public init(scratch: URL, timeout: TimeInterval = 120, accountName: @escaping () -> String? = { nil }) {
        self.scratch = scratch
        self.timeout = timeout
        self.accountName = accountName
    }

    public struct Account: Codable, Equatable {
        public var name: String
        public var upgraded: Bool
    }

    /// The accounts in Notes; also how access is asked for and checked.
    public func accounts() async throws -> [Account] {
        try await call("accounts", [:], as: [Account].self)
    }

    public func list() async throws -> [MacNoteInfo] {
        try await call("list", [:], as: [MacNoteInfo].self)
    }

    public func folders() async throws -> [String] {
        try await call("folders", [:], as: [String].self)
    }

    public func read(id: String, into folder: URL) async throws -> MacNoteContent {
        struct Answer: Codable {
            var id: String
            var name: String
            var folder: String
            var modified: Int64
            var html: String
            var attachments: [MacNoteContent.Attachment]
        }
        let answer = try await call("read", ["id": id, "dir": folder.path], as: Answer.self)
        return MacNoteContent(
            info: MacNoteInfo(id: answer.id, name: answer.name, folder: answer.folder, modified: answer.modified),
            html: answer.html,
            attachments: answer.attachments
        )
    }

    public func create(folder: String, html: String, files: [URL]) async throws -> MacNoteInfo {
        try await call("create", ["folder": folder, "htmlFile": try write(html), "files": files.map(\.path)], as: MacNoteInfo.self)
    }

    public func update(id: String, folder: String, html: String, files: [URL]) async throws -> MacNoteInfo {
        try await call(
            "update",
            ["id": id, "folder": folder, "htmlFile": try write(html), "files": files.map(\.path)],
            as: MacNoteInfo.self
        )
    }

    public func move(id: String, folder: String) async throws -> MacNoteInfo {
        try await call("move", ["id": id, "folder": folder], as: MacNoteInfo.self)
    }

    public func delete(id: String) async throws {
        _ = try await call("delete", ["id": id], as: Bool.self)
    }

    public func ensureFolder(_ name: String) async throws {
        _ = try await call("ensureFolder", ["folder": name], as: Bool.self)
    }

    // MARK: - Running the script

    /// The body goes through a file: a note with pictures in it is megabytes
    /// of base64, far past what a command line takes.
    private func write(_ html: String) throws -> String {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("body-\(UUID().uuidString).html")
        try Data(html.utf8).write(to: url)
        return url.path
    }

    private func call<T: Decodable>(_ op: String, _ arguments: [String: Any], as type: T.Type) async throws -> T {
        var request = arguments
        request["op"] = op
        if let account = accountName() { request["account"] = account }
        let output = try await run(request)
        do {
            return try JSONDecoder().decode(T.self, from: output)
        } catch {
            throw NotesLibraryError.failed("unexpected answer to \(op)")
        }
    }

    private func run(_ request: [String: Any]) async throws -> Data {
        launchQuietly()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appendingPathComponent("notes-bridge.js")
        if (try? String(contentsOf: script)) != Self.script {
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
        }
        let requestURL = scratch.appendingPathComponent("request-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            if let body = request["htmlFile"] as? String { try? FileManager.default.removeItem(atPath: body) }
        }
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", script.path, requestURL.path]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NotesLibraryError.failed(error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read before waiting: a big answer would otherwise fill the pipe and stall both sides.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                killer.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else if errors.contains("-1743") || errors.contains("Not authorized") || errors.contains("not allowed") {
                    continuation.resume(throwing: NotesLibraryError.notAuthorized)
                } else {
                    let detail = errors.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NotesLibraryError.failed(detail.isEmpty ? "osascript ended with \(process.terminationStatus)" : detail))
                }
            }
        }
    }

    /// Notes started by an Apple event opens its window in front of whatever
    /// the user is doing; started this way first, it stays out of sight.
    private func launchQuietly() {
        let bundle = "com.apple.Notes"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        let started = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in started.signal() }
        _ = started.wait(timeout: .now() + 10)
    }

    // MARK: - The script

    static let script = #"""
    ObjC.import('Foundation');

    function readText(path) {
      return $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
    }

    // Recently Deleted is a folder like any other to a script; its notes are not in use.
    const DELETED = ['Recently Deleted', 'Ostatnio usunięte', 'Zuletzt gelöscht', 'Supprimés récemment'];

    function pickAccount(Notes, name) {
      const accounts = Notes.accounts();
      if (name) {
        const named = accounts.filter(a => a.name() === name);
        if (named.length) return named[0];
      }
      const icloud = accounts.filter(a => a.name() === 'iCloud');
      if (icloud.length) return icloud[0];
      const upgraded = accounts.filter(a => a.upgraded());
      return upgraded.length ? upgraded[0] : Notes.defaultAccount();
    }

    function ensureFolder(Notes, account, name) {
      const found = account.folders().filter(f => f.name() === name);
      if (found.length) return found[0];
      return Notes.make({ new: 'folder', at: account, withProperties: { name: name } });
    }

    function info(note) {
      return { id: note.id(), name: note.name(), folder: note.container().name(), modified: note.modificationDate().getTime() };
    }

    // Notes reads a file the body refers to only once it was handed the file
    // by an Apple event: attaching it does that. The attachments made here go
    // again with the body set right after, which puts each file in its place.
    function grant(Notes, note, files) {
      (files || []).forEach(file => Notes.make({ new: 'attachment', at: note, withData: Path(file) }));
    }

    function safeName(name) {
      return String(name || 'attachment').replace(/[\/:\u0000-\u001f]/g, '_').slice(0, 120);
    }

    function run(argv) {
      const req = JSON.parse(readText(argv[0]));
      const Notes = Application('Notes');
      Notes.includeStandardAdditions = true;
      if (req.op === 'accounts') {
        return JSON.stringify(Notes.accounts().map(a => ({ name: a.name(), upgraded: a.upgraded() })));
      }
      const account = pickAccount(Notes, req.account);
      switch (req.op) {
        case 'folders':
          return JSON.stringify(account.folders().map(f => f.name()).filter(n => DELETED.indexOf(n) < 0));
        case 'list': {
          const out = [];
          const seen = {};
          account.folders().forEach(f => {
            const folder = f.name();
            if (DELETED.indexOf(folder) >= 0) return;
            const ids = f.notes.id();
            if (!ids.length) return;
            const names = f.notes.name();
            const dates = f.notes.modificationDate();
            const locked = f.notes.passwordProtected();
            for (let i = 0; i < ids.length; i++) {
              if (seen[ids[i]] || locked[i]) continue;
              seen[ids[i]] = true;
              out.push({ id: ids[i], name: names[i], folder: folder, modified: dates[i].getTime() });
            }
          });
          return JSON.stringify(out);
        }
        case 'read': {
          const note = Notes.notes.byId(req.id);
          const html = note.body();
          const attachments = [];
          const seen = {};
          note.attachments().forEach((a, i) => {
            const id = a.id();
            if (seen[id]) return;
            seen[id] = true;
            let name = null;
            try { name = a.name(); } catch (e) {}
            const file = req.dir + '/' + i + '-' + safeName(name);
            // A table is an attachment too, and one that cannot be saved; the body has it.
            try { Notes.save(a, { in: Path(file) }); attachments.push({ id: id, name: name, file: file }); } catch (e) {}
          });
          const result = info(note);
          result.html = html;
          result.attachments = attachments;
          return JSON.stringify(result);
        }
        case 'create': {
          const folder = ensureFolder(Notes, account, req.folder);
          const html = readText(req.htmlFile);
          const note = Notes.make({ new: 'note', at: folder, withProperties: { body: html } });
          if ((req.files || []).length) {
            grant(Notes, note, req.files);
            note.body = html;
          }
          return JSON.stringify(info(Notes.notes.byId(note.id())));
        }
        case 'update': {
          let note = Notes.notes.byId(req.id);
          grant(Notes, note, req.files);
          note.body = readText(req.htmlFile);
          if (req.folder && note.container().name() !== req.folder) {
            Notes.move(note, { to: ensureFolder(Notes, account, req.folder) });
            note = Notes.notes.byId(req.id);
          }
          return JSON.stringify(info(note));
        }
        case 'move': {
          const note = Notes.notes.byId(req.id);
          if (note.container().name() !== req.folder) Notes.move(note, { to: ensureFolder(Notes, account, req.folder) });
          return JSON.stringify(info(Notes.notes.byId(req.id)));
        }
        case 'delete':
          Notes.delete(Notes.notes.byId(req.id));
          return 'true';
        case 'ensureFolder':
          ensureFolder(Notes, account, req.folder);
          return 'true';
      }
      throw new Error('unknown operation ' + req.op);
    }
    """#
}
