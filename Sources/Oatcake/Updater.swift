// Checking for and installing new releases; the mechanics are in OatcakeCore's Update. A check runs
// 20 seconds after launch and then once a day (unless turned off in Settings), and from Settings'
// Check Now. Installing never starts while a call is being recorded, analysed or saved.

import AppKit
import OatcakeCore

@MainActor @Observable
final class Updater {
    struct Available: Equatable {
        var version: String
        var notes: String
        var size: Int
    }

    /// This copy's version.
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    var checking = false
    /// When the last check succeeded.
    var checkedAt: Date?
    /// A newer release, if there is one.
    var available: Available?
    /// Why this copy can't install it itself, and the Terminal command that can, when that helps.
    var blocked: String?
    var command: String?
    /// What an install in progress is doing ("Downloading… 40%").
    var installing: String?
    var error: String?

    private var manifest: Update.Manifest?
    private var lastCheck: Date?
    private var busy: () -> String? = { nil }
    private var timer: Timer?
    // OATCAKE_UPDATE_FEED points at another latest.json, for trying a release before it's published.
    private let feed = ProcessInfo.processInfo.environment["OATCAKE_UPDATE_FEED"].flatMap(URL.init(string:)) ?? Update.feedURL

    /// The running bundle, when this is a packaged app rather than a development build.
    private var bundle: URL? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    }

    func start(autoCheck: @escaping () -> Bool, busy: @escaping () -> String?) {
        self.busy = busy
        // Development copies check only when asked, unless pointed at a test feed.
        if bundle == nil && feed == Update.feedURL { return }
        let tick = { [weak self] in
            Task { @MainActor in
                guard let self, autoCheck(), self.lastCheck.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
                await self.check()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in _ = tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in _ = tick() }
    }

    /// Why this copy can't replace itself with the release, if it can't, and whether the install command would.
    private func whyBlocked(_ m: Update.Manifest) -> (String?, String?) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if Update.compareVersions("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", m.minimumSystemVersion) < 0 {
            return ("Oatcake \(m.version) needs macOS \(m.minimumSystemVersion) or later.", nil)
        }
        guard let bundle else { return ("This is a development copy of Oatcake: update it with git.", nil) }
        if bundle.path.contains("/AppTranslocation/") {
            return ("Move Oatcake to your Applications folder and open it from there; then it can update itself.", nil)
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return ("Oatcake can't replace itself in \(bundle.deletingLastPathComponent().path). Install the update from Terminal instead:", Update.installCommand)
        }
        do {
            if Update.isAdHoc(try Update.designatedRequirement(bundle)) {
                return ("This copy of Oatcake wasn't signed for updates. Install the update from Terminal instead:", Update.installCommand)
            }
        } catch {
            return (error.localizedDescription, nil)
        }
        return (nil, nil)
    }

    func check() async {
        guard !checking, installing == nil else { return }
        checking = true
        error = nil
        do {
            let m = try await Update.fetchManifest(feed)
            lastCheck = Date()
            checkedAt = Date()
            if Update.compareVersions(m.version, current) > 0 {
                manifest = m
                available = Available(version: m.version, notes: m.notes, size: m.zip.size)
                (blocked, command) = whyBlocked(m)
            } else {
                manifest = nil
                available = nil
                (blocked, command) = (nil, nil)
            }
        } catch {
            self.error = error.localizedDescription
        }
        checking = false
    }

    func install() async {
        guard let m = manifest, installing == nil, blocked == nil, let bundle else { return }
        if let reason = busy() {
            error = reason
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            installing = "Downloading…"
            error = nil
            let zip = try await Update.downloadZip(m, into: tmp) { fraction in
                let text = "Downloading… \(Int(fraction * 100))%"
                Task { @MainActor in if self.installing != text { self.installing = text } }
            }
            installing = "Checking…"
            let requirement = try Update.designatedRequirement(bundle)
            let staged = try await Task.detached { () throws -> URL in
                let app = try Update.unpack(zip, into: tmp, manifest: m)
                guard Update.satisfies(app, requirement) else {
                    throw OatcakeError("The update isn't signed with the same certificate as this copy of Oatcake, so it wasn't installed.")
                }
                return try Update.stage(app, beside: bundle, requirement: requirement)
            }.value
            installing = "Installing…"
            // A call may have started during the download.
            if let reason = busy() {
                try? FileManager.default.removeItem(at: staged)
                throw OatcakeError(reason)
            }
            try Update.swapAfterExit(installed: bundle, staged: staged)
            installing = "Relaunching…"
            NSApp.terminate(nil)
        } catch {
            installing = nil
            self.error = error.localizedDescription
        }
    }
}
