import AppKit

@MainActor
class UpdateManager {
    static let shared = UpdateManager()

    private let repoOwner = "mikezielonkadotcom"
    private let repoName = "scrt.link-mac-app"
    private var isChecking = false

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    // MARK: - Public

    func checkForUpdatesInBackground() {
        checkForUpdates(silent: true)
    }

    func checkForUpdatesInteractive() {
        checkForUpdates(silent: false)
    }

    // MARK: - Core Logic

    private func checkForUpdates(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { @MainActor in
                self?.isChecking = false
                self?.handleResponse(data: data, response: response, error: error, silent: silent)
            }
        }
        task.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, silent: Bool) {
        if let error = error {
            if !silent {
                showAlert(title: "Update Check Failed", message: "Could not reach GitHub: \(error.localizedDescription)")
            }
            return
        }

        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            if !silent {
                showAlert(title: "Update Check Failed", message: "Could not parse release information from GitHub.")
            }
            return
        }

        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        if Self.isNewerVersion(remote: remoteVersion, current: currentVersion) {
            let body = json["body"] as? String ?? ""
            promptForUpdate(version: remoteVersion, releaseNotes: body, assets: json["assets"] as? [[String: Any]] ?? [])
        } else if !silent {
            showAlert(title: "Up to Date", message: "You're running the latest version (\(currentVersion)).")
        }
    }

    private func promptForUpdate(version: String, releaseNotes: String, assets: [[String: Any]]) {
        guard let downloadURL = Self.releaseDownloadURL(version: version, assets: assets,
                                                        repoOwner: repoOwner, repoName: repoName) else {
            showAlert(title: "Update Available (v\(version))", message: "A new version is available but no downloadable package was found.\n\nPlease update manually from GitHub.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(version) is available (you have \(currentVersion)).\n\n\(releaseNotes.prefix(300))"
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(url: downloadURL, version: version)
        }
    }

    // MARK: - Download & Install

    private func downloadAndInstall(url: URL, version: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating..."
        window.center()

        let label = NSTextField(labelWithString: "Downloading update v\(version)...")
        label.frame = NSRect(x: 20, y: 40, width: 260, height: 20)
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 15, width: 260, height: 20))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(progress)
        window.makeKeyAndOrderFront(nil)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            // URLSession deletes its temp file once this handler returns, so
            // claim the download here, on the session's background queue,
            // before hopping to the main actor.
            let claimed: Result<(zip: URL, dir: URL), Error>
            if let error {
                claimed = .failure(error)
            } else if let tempURL {
                claimed = Result { try Self.claimDownload(tempURL) }
            } else {
                claimed = .failure(UpdateInstallError.failed("No file was downloaded."))
            }

            DispatchQueue.main.async { @MainActor in
                switch claimed {
                case .failure(let error):
                    window.close()
                    self?.showAlert(title: "Download Failed", message: error.localizedDescription)
                case .success(let download):
                    label.stringValue = "Verifying update v\(version)..."
                    self?.installUpdate(zipURL: download.zip, tempDir: download.dir, version: version,
                                        progressWindow: window)
                }
            }
        }
        task.resume()
    }

    /// Unpacks, stages and verifies the update off the main actor while the
    /// progress window stays up, then swaps the bundle into place on the main
    /// actor. Before this split the whole install (ditto, codesign, spctl and
    /// a copy of the entire .app) blocked the UI with no window explaining why.
    private func installUpdate(zipURL: URL, tempDir: URL, version: String, progressWindow: NSWindow) {
        let currentAppURL = Bundle.main.bundleURL
        let teamID = Bundle.main.object(forInfoDictionaryKey: "ScrtLinkTeamID") as? String
        let bundleID = Bundle.main.bundleIdentifier

        Task { [weak self] in
            let staged = await Task.detached(priority: .userInitiated) {
                Result { try Self.stageUpdate(zipURL: zipURL, tempDir: tempDir, version: version,
                                              currentAppURL: currentAppURL, teamID: teamID, bundleID: bundleID) }
            }.value

            guard let self else { progressWindow.close(); return }
            switch staged {
            case .failure(UpdateInstallError.rejected):
                progressWindow.close()
                self.showAlert(title: "Update Rejected", message: "The update did not pass app identity and Apple signature checks. Download it manually from the project release page if needed.")
            case .failure(let error):
                progressWindow.close()
                self.showAlert(title: "Update Failed", message: error.localizedDescription)
            case .success(let stagedURL):
                self.swapInStagedUpdate(stagedURL, currentAppURL: currentAppURL, progressWindow: progressWindow)
            }
        }
    }

    /// Copies URLSession's temporary download into a private working
    /// directory. Returns the ZIP and the directory to clean up.
    nonisolated private static func claimDownload(_ tempURL: URL) throws -> (zip: URL, dir: URL) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("ScrtLink-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let zipDest = tempDir.appendingPathComponent("update.zip")
        do {
            try fileManager.copyItem(at: tempURL, to: zipDest)
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw error
        }
        return (zipDest, tempDir)
    }

    /// Extracts the ZIP, copies the bundle to a staged path beside the
    /// installed app, and verifies that staged copy: the exact bytes that will
    /// be moved into place, not the extraction in the temp directory. Removes
    /// the temp directory on every path and the staged copy on failure.
    nonisolated private static func stageUpdate(zipURL: URL, tempDir: URL, version: String,
                                                currentAppURL: URL, teamID: String?, bundleID: String?) throws -> URL {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: tempDir) }

        guard run("/usr/bin/ditto", ["-x", "-k", zipURL.path, tempDir.path]) else {
            throw UpdateInstallError.failed("Could not unzip the update package.")
        }

        let newApp = tempDir.appendingPathComponent("ScrtLink.app")
        guard fileManager.fileExists(atPath: newApp.path),
              newApp.resolvingSymlinksInPath().path.hasPrefix(tempDir.resolvingSymlinksInPath().path + "/") else {
            throw UpdateInstallError.failed("No .app found in the update package.")
        }

        let stagedURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(".ScrtLink-update-\(UUID().uuidString).app")
        try fileManager.copyItem(at: newApp, to: stagedURL)

        guard verifyUpdate(stagedURL, version: version, teamID: teamID, bundleID: bundleID) else {
            try? fileManager.removeItem(at: stagedURL)
            throw UpdateInstallError.rejected
        }
        return stagedURL
    }

    /// The two renames and the relaunch. Fast, so they stay on the main actor.
    private func swapInStagedUpdate(_ stagedURL: URL, currentAppURL: URL, progressWindow: NSWindow) {
        let fileManager = FileManager.default
        let backupURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(".ScrtLink-backup-\(UUID().uuidString).app")

        do {
            do {
                try fileManager.moveItem(at: currentAppURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: stagedURL, to: currentAppURL)
                } catch {
                    let installError = error
                    do {
                        try fileManager.moveItem(at: backupURL, to: currentAppURL)
                    } catch {
                        throw updateError("Installation failed and the old app could not be restored. Its backup is at \(backupURL.path). \(error.localizedDescription)")
                    }
                    throw installError
                }
            } catch {
                try? fileManager.removeItem(at: stagedURL)
                throw error
            }

            guard Self.run("/usr/bin/open", ["-n", currentAppURL.path]) else {
                do {
                    try fileManager.removeItem(at: currentAppURL)
                    try fileManager.moveItem(at: backupURL, to: currentAppURL)
                } catch {
                    throw updateError("The new app could not launch and the old app could not be restored. Its backup is at \(backupURL.path). \(error.localizedDescription)")
                }
                throw updateError("The new app could not launch. The old app was restored.")
            }

            // Keep the old app as a recovery copy. A successful `open` only
            // confirms LaunchServices accepted the new app, not that its UI
            // will keep running. Never discard the backup in this process.

            progressWindow.close()
            NSApp.terminate(nil)

        } catch {
            progressWindow.close()
            showAlert(title: "Update Failed", message: error.localizedDescription)
        }
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "com.mikezielonka.scrt-link.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Release gates
    //
    // These are static and take their inputs explicitly so the offline test
    // suite (tests/UpdateManagerTests) can exercise them against a real
    // bundle without an installed app, a network connection, or an alert.

    /// The only download URL the updater will fetch for `version`: the exact
    /// versioned ZIP on github.com under this repository's releases path.
    /// Anything else, including a lookalike host or a different repository,
    /// yields nil and the user is sent to the release page instead.
    nonisolated static func releaseDownloadURL(version: String, assets: [[String: Any]],
                                               repoOwner: String, repoName: String) -> URL? {
        let expectedName = "ScrtLink-v\(version).zip"
        guard let asset = assets.first(where: { ($0["name"] as? String) == expectedName }),
              let downloadURLString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString),
              downloadURL.scheme == "https",
              downloadURL.host == "github.com",
              downloadURL.user == nil, downloadURL.port == nil,
              downloadURL.path == "/\(repoOwner)/\(repoName)/releases/download/v\(version)/\(expectedName)" else {
            return nil
        }
        return downloadURL
    }

    /// Identity, version, pinned Apple team, signature and Gatekeeper checks
    /// for a candidate bundle. `teamID` is the value sealed into the running
    /// app's Info.plist by release.sh; without a valid one (local ad hoc
    /// builds) no update is ever installed.
    nonisolated static func verifyUpdate(_ app: URL, version: String, teamID: String?, bundleID: String?) -> Bool {
        guard let teamID, !teamID.isEmpty,
              teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let bundleID, !bundleID.isEmpty,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            return false
        }

        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleID)\""
        return run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=\(requirement)", app.path])
            && run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Version Comparison

    /// Numeric dotted comparison ("1.10.0" is newer than "1.9.9"). Missing
    /// components count as 0 and non-numeric components are ignored.
    nonisolated static func isNewerVersion(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Outcomes of staging an update that need distinct user-facing alerts.
enum UpdateInstallError: LocalizedError {
    /// A step failed; the message is shown as-is.
    case failed(String)
    /// The bundle did not pass the identity, team, signature or Gatekeeper gates.
    case rejected

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .rejected: return "The update did not pass app identity and Apple signature checks."
        }
    }
}
