// Updates. Each GitHub release carries latest.json: a manifest naming the version and its zip
// (address, SHA-256, size), signed with Oatcake's Ed25519 release key. Oatcake reads it, downloads
// the zip, checks it's exactly the file that was signed, checks the app inside carries the same
// code-signing identity as the running copy, and swaps itself for it once it has quit.
//
// Oatcake isn't notarised. Files it downloads itself (like files curl downloads) get no
// quarantine flag, so Gatekeeper never looks at them; these checks stand in for it.
// install.sh reads the same manifest for first installs.

import CryptoKit
import Foundation

public enum Update {
    public static let feedURL = URL(string: "https://github.com/a8cteam51/oatcake/releases/latest/download/latest.json")!
    public static let installCommand = "curl -fsSL https://raw.githubusercontent.com/a8cteam51/oatcake/trunk/install.sh | sh"
    public static let bundleID = "local.oatcake"
    static let appName = "Oatcake.app"

    /// Ed25519 public keys (raw 32 bytes, base64) that may sign latest.json. The private key is the
    /// OATCAKE_UPDATE_KEY secret the Release workflow uses. To replace the key, add the new public
    /// key here and ship a release signed with the old one before releases are signed with the new.
    public static let publicKeys = ["FQF4wZO3mslNx4xt76rEW5y28nlAeEfKQyIm0wAWPh0="]

    public struct Manifest: Codable, Sendable {
        public struct Zip: Codable, Sendable {
            public var name: String
            public var url: String
            public var sha256: String
            public var size: Int
        }
        public var bundleID: String
        public var version: String
        public var minimumSystemVersion: String
        public var published: String
        /// Plain text, one change per line.
        public var notes: String
        public var zip: Zip
    }

    /// Compares dotted version numbers part by part: 1 when a is newer, -1 when older, 0 when equal.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d > 0 ? 1 : -1 }
        }
        return 0
    }

    /// Checks latest.json's signature against the keys Oatcake ships with, then reads what it signed.
    public static func readManifest(_ envelope: Data, keys: [String] = publicKeys) throws -> Manifest {
        guard let json = (try? JSONSerialization.jsonObject(with: envelope)) as? [String: Any],
              let payload = (json["payload"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let signature = (json["signature"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw OatcakeError("The update information isn't in the expected format.")
        }
        let signed = keys.contains { key in
            guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return publicKey.isValidSignature(signature, for: payload)
        }
        guard signed else { throw OatcakeError("The update information isn't signed with Oatcake's release key.") }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: payload),
              m.bundleID == bundleID,
              m.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              m.minimumSystemVersion.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil,
              m.zip.name.range(of: #"^[\w.-]+\.zip$"#, options: .regularExpression) != nil,
              m.zip.url.hasPrefix("https://"),
              m.zip.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              m.zip.size > 0 else {
            throw OatcakeError("The update information is incomplete.")
        }
        return m
    }

    /// Fetches and checks the manifest. A feed other than the real one (for testing) serves its zip beside it.
    public static func fetchManifest(_ feed: URL) async throws -> Manifest {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        } catch {
            throw OatcakeError("Couldn't reach GitHub to check for updates.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw OatcakeError("No release of Oatcake is published yet.") }
        guard status == 200 else { throw OatcakeError("Couldn't check for updates (HTTP \(status)).") }
        var manifest = try readManifest(data)
        if feed != feedURL { manifest.zip.url = feed.deletingLastPathComponent().appendingPathComponent(manifest.zip.name).absoluteString }
        return manifest
    }

    /// Downloads the release zip into dir, checking its size and SHA-256 against the manifest.
    public static func downloadZip(_ manifest: Manifest, into dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: manifest.zip.url) else { throw OatcakeError("The update's address isn't valid.") }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 60))
        } catch {
            throw OatcakeError("Couldn't download the update. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OatcakeError("The download failed (HTTP \(status)).") }
        let file = dir.appendingPathComponent(manifest.zip.name)
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var received = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                received += buffer.count
                if received > manifest.zip.size { throw OatcakeError("The download is bigger than the release said it would be.") }
                hash.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(received) / Double(manifest.zip.size))
            }
        }
        received += buffer.count
        hash.update(data: buffer)
        try handle.write(contentsOf: buffer)
        guard received == manifest.zip.size else { throw OatcakeError("The download stopped early (\(received) of \(manifest.zip.size) bytes).") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.zip.sha256 else { throw OatcakeError("The download doesn't match the release's checksum.") }
        progress(1)
        return file
    }

    static func plistValue(_ app: URL, _ key: String) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?[key] as? String
    }

    /// Unpacks the zip (ditto keeps code signatures intact) and checks it holds just Oatcake.app, of the manifest's version.
    public static func unpack(_ zip: URL, into dir: URL, manifest: Manifest) throws -> URL {
        let out = dir.appendingPathComponent("unpacked")
        try runCapturing("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let entries = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0 != "__MACOSX" }
        guard entries == [appName] else { throw OatcakeError("The download doesn't contain just Oatcake.app.") }
        let app = out.appendingPathComponent(appName)
        guard plistValue(app, "CFBundleIdentifier") == bundleID else { throw OatcakeError("The download isn't Oatcake.") }
        guard plistValue(app, "CFBundleShortVersionString") == manifest.version else { throw OatcakeError("The download isn't Oatcake \(manifest.version).") }
        return app
    }

    /**
     * The code-signing requirement a bundle's signature names for itself, e.g.
     * `identifier "local.oatcake" and certificate leaf = H"…"`. An ad-hoc signature's is `cdhash H"…"`,
     * which no other build can meet.
     */
    public static func designatedRequirement(_ bundle: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r", "-", bundle.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = text.components(separatedBy: "\n").first(where: { $0.contains("designated =>") }),
              let range = line.range(of: "designated =>") else { throw OatcakeError("Couldn't read Oatcake's code signature.") }
        return String(line[range.upperBound...]).trimmed
    }

    public static func isAdHoc(_ requirement: String) -> Bool { requirement.hasPrefix("cdhash") }

    /// Whether a bundle is validly signed, unmodified, and meets the requirement (the same identity as this copy).
    public static func satisfies(_ bundle: URL, _ requirement: String) -> Bool {
        (try? runCapturing("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=\(requirement)", bundle.path])) != nil
    }

    /// Copies the new app beside the installed one (same volume, so the swap is a rename) and checks the copy.
    public static func stage(_ app: URL, beside installed: URL, requirement: String) throws -> URL {
        let staged = installed.deletingLastPathComponent().appendingPathComponent(".Oatcake-update.app")
        try? FileManager.default.removeItem(at: staged)
        try runCapturing("/usr/bin/ditto", [app.path, staged.path])
        guard satisfies(staged, requirement) else {
            try? FileManager.default.removeItem(at: staged)
            throw OatcakeError("The copied update failed its signature check.")
        }
        return staged
    }

    // Waits for Oatcake to quit, swaps the bundles, and opens whichever is in place: the new one, or
    // the old one put back if the swap failed. Runs detached, so it outlives the app.
    private static let swapScript = #"""
    pid=$1 dest=$2 staged=$3
    old="$(dirname "$dest")/.Oatcake-old-$pid.app"
    echo "$(date): updating $dest"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 600 ]; then echo "Oatcake didn't quit; update abandoned"; rm -rf "$staged"; exit 1; fi
      sleep 0.2
    done
    if mv "$dest" "$old"; then
      if mv "$staged" "$dest"; then
        rm -rf "$old"
        echo "updated"
      else
        mv "$old" "$dest"
        rm -rf "$staged"
        echo "couldn't move the update into place; kept the old copy"
      fi
    else
      rm -rf "$staged"
      echo "couldn't move the old copy aside; kept it"
    fi
    touch "$dest"
    /usr/bin/open "$dest"
    """#

    /// Starts the swap; the caller quits straight after. Its output goes to update.log in Oatcake's data folder.
    public static func swapAfterExit(installed: URL, staged: URL) throws {
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        if !FileManager.default.exists(Paths.updateLog) { FileManager.default.createFile(atPath: Paths.updateLog.path, contents: nil) }
        let log = try FileHandle(forWritingTo: Paths.updateLog)
        log.seekToEndOfFile()
        let process = Process()
        // A child process outlives Oatcake: it's handed to launchd when Oatcake exits.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "oatcake-update", String(getpid()), installed.path, staged.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }
}
