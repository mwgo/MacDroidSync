import AppKit
import MacDroidSyncCore

/// Checks GitHub once a day while the app runs and, when switched on, installs
/// a newer release over itself and relaunches.
///
/// Nothing is installed unless the archive carries a valid Ed25519 signature
/// for `UpdateKey.publicKey`: the bundle is signed ad hoc, so its own code
/// signature says nothing about who built it.
final class Updater {

    var onStatusChange: (() -> Void)?
    /// Asked before relaunching; false postpones the restart, e.g. mid transfer.
    var canRestartNow: () -> Bool = { true }
    var onInstalled: ((String) -> Void)?

    private(set) var status = "Not checked yet"
    private(set) var isBusy = false

    private let settings = Settings.shared
    private var timer: Timer?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    private var currentVersion: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    // MARK: - Schedule

    func start() {
        announceFinishedUpdate()
        if let last = settings.lastUpdateCheckAt { status = "Last checked \(Self.format(last))" }
        // Once an hour is only how often "is a check due" is asked; the check
        // itself happens once a day.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        // Not at the very moment of launch, which after a reboot is when the
        // network is least likely to be there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func enabledChanged() {
        if settings.autoUpdateEnabled { checkIfDue() }
    }

    private func checkIfDue() {
        guard settings.autoUpdateEnabled,
              UpdateSchedule.isDue(lastCheck: settings.lastUpdateCheckAt, now: Date())
        else { return }
        check(install: true)
    }

    /// `install` false only reports what is available.
    func check(install: Bool) {
        guard !isBusy, let current = currentVersion else { return }
        isBusy = true
        set(status: "Checking…")

        var request = URLRequest(url: UpdateFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacDroidSync/\(current)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleFeed(data: data, response: response, error: error, current: current, install: install)
            }
        }.resume()
    }

    private func handleFeed(data: Data?, response: URLResponse?, error: Error?, current: AppVersion, install: Bool) {
        // A failed check is not recorded, so the next hourly tick tries again.
        if let error {
            finish(status: "Could not check: \(error.localizedDescription)")
            return
        }
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(status: "Could not check: GitHub answered \(code)")
            return
        }
        settings.lastUpdateCheckAt = Date()
        do {
            guard let update = try UpdateFeed.update(from: data, newerThan: current) else {
                finish(status: "Up to date (\(current)), checked \(Self.format(Date()))")
                return
            }
            Log.info("Update available: \(update.version)")
            guard install else {
                finish(status: "Version \(update.version) is available")
                return
            }
            download(update)
        } catch UpdateFeed.FeedError.noArchive(let name) {
            finish(status: "The latest release has no \(name)")
        } catch {
            finish(status: "Could not read the release from GitHub")
        }
    }

    // MARK: - Installing

    private func download(_ update: AvailableUpdate) {
        guard let publicKey = UpdateKey.publicKey else {
            finish(status: "Version \(update.version) is available, but this build has no key to verify it")
            return
        }
        guard let signatureURL = update.signatureURL else {
            finish(status: "Version \(update.version) is not signed and was not installed")
            return
        }
        set(status: "Downloading \(update.version)…")

        let group = DispatchGroup()
        var archive: Data?
        var signature: Data?
        var failure: String?
        for (url, assign) in [
            (update.archiveURL, { (data: Data) in archive = data }),
            (signatureURL, { (data: Data) in signature = data }),
        ] {
            group.enter()
            session.dataTask(with: url) { data, response, error in
                if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                    assign(data)
                } else {
                    failure = error?.localizedDescription ?? "the download failed"
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard let archive, let signature else {
                self.finish(status: "Could not download \(update.version): \(failure ?? "incomplete")")
                return
            }
            guard UpdateSignature.isValid(archive: archive, signature: signature, publicKey: publicKey) else {
                Log.error("The signature of \(update.version) does not verify; not installing it")
                self.finish(status: "Version \(update.version) failed signature verification and was not installed")
                return
            }
            self.install(archive: archive, version: update.version)
        }
    }

    private func install(archive: Data, version: AppVersion) {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") {
            finish(status: "Move MacDroidSync.app out of Downloads to update it")
            return
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            finish(status: "No permission to replace the app in \(bundle.deletingLastPathComponent().path)")
            return
        }
        set(status: "Installing \(version)…")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Self.replace(bundle: bundle, with: archive, version: version) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    Log.error("Installing \(version) failed: \(error.localizedDescription)")
                    self.finish(status: "Installing \(version) failed: \(error.localizedDescription)")
                case .success:
                    Log.info("Installed \(version), relaunching")
                    self.settings.pendingUpdateNotice = version.description
                    self.set(status: "Installed \(version), restarting…")
                    self.relaunchWhenIdle(bundle: bundle)
                }
            }
        }
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func replace(bundle: URL, with archive: Data, version: AppVersion) throws {
        let files = FileManager.default
        // On the same volume as the app, so the swap is a rename.
        let work = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true
        )
        defer { try? files.removeItem(at: work) }

        let zip = work.appendingPathComponent("update.zip")
        try archive.write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

        let apps = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw InstallError("the archive holds no single app") }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw InstallError("the archive holds a different app")
        }
        guard (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw InstallError("the archive holds a different version than announced")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        _ = try files.replaceItemAt(bundle, withItemAt: app)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError("\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func relaunchWhenIdle(bundle: URL) {
        guard canRestartNow() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.relaunchWhenIdle(bundle: bundle)
            }
            return
        }
        // A detached shell waits for this process to be gone, then opens the
        // new bundle; otherwise `open` would just bring the old instance forward.
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "relaunch", bundle.path]
        do {
            try process.run()
        } catch {
            finish(status: "Installed, but could not restart: \(error.localizedDescription). Quit and open the app again.")
            return
        }
        NSApp.terminate(nil)
    }

    private func announceFinishedUpdate() {
        guard let pending = settings.pendingUpdateNotice else { return }
        settings.pendingUpdateNotice = nil
        if let current = currentVersion, AppVersion(pending) == current {
            Log.info("Now running \(current) after an update")
            status = "Updated to \(current)"
            onInstalled?(current.description)
        }
    }

    private func set(status text: String) {
        status = text
        onStatusChange?()
    }

    private func finish(status text: String) {
        isBusy = false
        set(status: text)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
