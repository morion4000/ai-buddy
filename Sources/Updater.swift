import AppKit

/// Self-updater backed by a JSON appcast on updates.claudete.co (the same R2
/// bucket Claudete's updater uses). No Sparkle, no frameworks.
///
/// Flow: poll the appcast → if its version is newer than our
/// CFBundleShortVersionString, offer to install → download the DMG,
/// mount it, verify the new app's code signature (same Team ID as the running
/// app — a hijacked download or tampered asset fails here), swap the installed
/// bundle, and relaunch. `RELEASE=1 ./make-dmg.sh` publishes the feed.
///
/// The swap works while running because the old executable stays mapped after
/// its directory is renamed away; the relaunch then loads the new bundle.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let feedURL = URL(string: "https://updates.claudete.co/ai-buddy/appcast.json")!
    private static let downloadPage = URL(string: "https://claudete.co/ai-buddy")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var inFlight = false

    /// Silent daily check, called on launch. Only surfaces UI when an update exists.
    func checkAutomatically() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    /// Menu-driven check: also reports "up to date" and failures.
    func check(userInitiated: Bool) {
        guard !inFlight else { return }
        inFlight = true
        Task {
            defer { inFlight = false }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            do {
                guard let release = try await Self.fetchLatestRelease() else {
                    if userInitiated { Self.info("You're up to date", "AI Buddy \(Self.currentVersion) is the latest version.") }
                    return
                }
                promptToInstall(release)
            } catch {
                guard userInitiated else { return } // background check failing is uninteresting
                Self.info("Update check failed", error.localizedDescription)
            }
        }
    }

    // MARK: Release lookup

    private struct Release {
        let version: String
        let dmgURL: URL
        let notes: String
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the latest release if it's newer than the running version, else nil.
    /// No appcast published yet (404) also returns nil.
    private static func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw Failure("Unexpected response from the update feed.")
        }
        guard isNewer(version, than: currentVersion) else { return nil }
        return Release(version: version, dmgURL: url, notes: json["notes"] as? String ?? "")
    }

    /// Numeric dotted-component compare: "1.10" > "1.9", missing components are 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    private func promptToInstall(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "AI Buddy \(release.version) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have \(Self.currentVersion)."
            + (notes.isEmpty ? "" : "\n\n\(notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)")
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await Self.downloadAndInstall(release)
                // Not reached on success — the app relaunches. Reached only if
                // terminate was blocked; the new version is installed regardless.
            } catch {
                Self.installFailed(error)
            }
        }
    }

    /// Everything on the way to the swap happens against temp paths, so a failure
    /// at any step leaves the installed app untouched.
    private static func downloadAndInstall(_ release: Release) async throws {
        let (download, _) = try await URLSession.shared.download(from: release.dmgURL)
        let dmg = download.deletingLastPathComponent()
            .appendingPathComponent("AIBuddy-update-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: download, to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }

        let mount = try run("/usr/bin/hdiutil",
                            ["attach", dmg.path, "-nobrowse", "-noverify", "-noautoopen", "-readonly"])
        guard let mountPoint = mount.components(separatedBy: "\n")
            .compactMap({ line -> String? in
                guard let r = line.range(of: "/Volumes/") else { return nil }
                return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            })
            .first else {
            throw Failure("Couldn't mount the update image.")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"]) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure("The update image contains no app.")
        }
        let newApp = "\(mountPoint)/\(appName)"

        try verifySignature(of: newApp)

        // Stage a copy outside the DMG so we can detach before relaunching.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBuddy-staged-\(release.version).app").path
        try? FileManager.default.removeItem(atPath: staged)
        _ = try run("/usr/bin/ditto", [newApp, staged])

        // Swap: move the running bundle aside, then the new one into place. If the
        // second move fails (e.g. permissions), put the old app back.
        let installed = Bundle.main.bundleURL.path
        let old = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBuddy-old-\(UUID().uuidString).app").path
        try FileManager.default.moveItem(atPath: installed, toPath: old)
        do {
            try FileManager.default.moveItem(atPath: staged, toPath: installed)
        } catch {
            try? FileManager.default.moveItem(atPath: old, toPath: installed)
            throw error
        }
        try? FileManager.default.removeItem(atPath: old)

        await relaunch(installed)
    }

    /// The downloaded app must carry a valid, non-ad-hoc signature from the same
    /// team as the running app. If the running app has no team (dev build), we
    /// refuse to auto-install rather than weaken the check.
    private static func verifySignature(of appPath: String) throws {
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])
        guard let ours = teamID(of: Bundle.main.bundlePath) else {
            throw Failure("This build isn't signed with a Developer ID, so updates can't be verified. Download the new version from the website.")
        }
        guard teamID(of: appPath) == ours else {
            throw Failure("The downloaded update isn't signed by the expected developer.")
        }
    }

    /// TeamIdentifier from `codesign -dv`, or nil when unsigned/ad-hoc ("not set").
    private static func teamID(of path: String) -> String? {
        guard let out = try? run("/usr/bin/codesign", ["-dv", path]) else { return nil }
        for line in out.components(separatedBy: "\n") where line.hasPrefix("TeamIdentifier=") {
            let id = String(line.dropFirst("TeamIdentifier=".count))
            return id == "not set" ? nil : id
        }
        return nil
    }

    /// Reopens the (new) bundle after we exit. The helper outlives us because
    /// `open` waits out the 1s sleep in its own process.
    private static func relaunch(_ appPath: String) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appPath)\""]
        try? p.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    // MARK: Helpers

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Runs a tool, returning stdout+stderr; throws (with that output as the
    /// message) on a non-zero exit. codesign and hdiutil both report on stderr.
    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw Failure(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func installFailed(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't install the update"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadPage)
        }
    }

    private static func info(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
