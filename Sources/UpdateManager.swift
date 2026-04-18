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

        if isNewerVersion(remote: remoteVersion, current: currentVersion) {
            let body = json["body"] as? String ?? ""
            promptForUpdate(version: remoteVersion, releaseNotes: body, assets: json["assets"] as? [[String: Any]] ?? [])
        } else if !silent {
            showAlert(title: "Up to Date", message: "You're running the latest version (\(currentVersion)).")
        }
    }

    private func promptForUpdate(version: String, releaseNotes: String, assets: [[String: Any]]) {
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let downloadURLString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
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

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async { @MainActor in
                window.close()

                if let error = error {
                    self?.showAlert(title: "Download Failed", message: error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
                    self?.showAlert(title: "Download Failed", message: "No file was downloaded.")
                    return
                }

                self?.installUpdate(from: tempURL)
            }
        }
        task.resume()
    }

    private func installUpdate(from zipURL: URL) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("ScrtLink-update-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let zipDest = tempDir.appendingPathComponent("update.zip")
            try fileManager.copyItem(at: zipURL, to: zipDest)

            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", zipDest.path, "-d", tempDir.path]
            try unzipProcess.run()
            unzipProcess.waitUntilExit()

            guard unzipProcess.terminationStatus == 0 else {
                showAlert(title: "Update Failed", message: "Could not unzip the update package.")
                return
            }

            let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                showAlert(title: "Update Failed", message: "No .app found in the update package.")
                return
            }

            guard let currentAppURL = Bundle.main.bundleURL as URL? else {
                showAlert(title: "Update Failed", message: "Could not determine current app location.")
                return
            }

            let backupURL = tempDir.appendingPathComponent("ScrtLink-old.app")
            try fileManager.moveItem(at: currentAppURL, to: backupURL)
            try fileManager.copyItem(at: newApp, to: currentAppURL)

            let xattrProcess = Process()
            xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProcess.arguments = ["-cr", currentAppURL.path]
            try? xattrProcess.run()
            xattrProcess.waitUntilExit()

            let relaunchProcess = Process()
            relaunchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunchProcess.arguments = ["-n", currentAppURL.path]
            try relaunchProcess.run()

            NSApp.terminate(nil)

        } catch {
            showAlert(title: "Update Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Version Comparison

    private func isNewerVersion(remote: String, current: String) -> Bool {
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
