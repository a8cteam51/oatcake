// Writes latest.json, a release's signed update manifest, to stdout. Oatcake's updater and
// install.sh read it (see Sources/OatcakeCore/Update.swift). The Release workflow runs it:
//
//   OATCAKE_UPDATE_KEY=… swift Scripts/sign-manifest.swift --app build/Oatcake.app \
//     --zip Oatcake-v0.4.0-arm64.zip --url https://github.com/…/Oatcake-v0.4.0-arm64.zip [--notes notes.txt]
//
// OATCAKE_UPDATE_KEY is the Ed25519 private key (base64 PKCS#8 DER); `swift Scripts/sign-manifest.swift
// keygen` prints a new pair. The manifest is checked against the public keys the app ships
// (Update.publicKeys) before it's written, so a release can't go out signed with a key the app refuses.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// PKCS#8 wrapping of a raw 32-byte Ed25519 private key.
let pkcs8Prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "keygen" {
    let key = Curve25519.Signing.PrivateKey()
    print("Private (the OATCAKE_UPDATE_KEY secret): \((pkcs8Prefix + key.rawRepresentation).base64EncodedString())")
    print("Public (add to Update.publicKeys): \(key.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

var options: [String: String] = [:]
var i = 0
while i < args.count {
    guard args[i].hasPrefix("--"), i + 1 < args.count else { fail("Unexpected argument \(args[i])") }
    options[String(args[i].dropFirst(2))] = args[i + 1]
    i += 2
}
guard let app = options["app"], let zipPath = options["zip"], let url = options["url"] else {
    fail("Usage: swift Scripts/sign-manifest.swift --app <Oatcake.app> --zip <zip> --url <zip's address> [--notes <file>]")
}
guard let encoded = ProcessInfo.processInfo.environment["OATCAKE_UPDATE_KEY"], let der = Data(base64Encoded: encoded) else {
    fail("OATCAKE_UPDATE_KEY isn't set.")
}
guard der.count == 48, der.prefix(16) == pkcs8Prefix, let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32)) else {
    fail("OATCAKE_UPDATE_KEY isn't an Ed25519 private key in PKCS#8 DER.")
}

guard let info = NSDictionary(contentsOfFile: "\(app)/Contents/Info.plist") as? [String: Any] else { fail("Can't read \(app)/Contents/Info.plist") }
guard let zip = FileManager.default.contents(atPath: zipPath) else { fail("Can't read \(zipPath)") }
let notes = options["notes"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let published = ISO8601DateFormatter()
published.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

struct Manifest: Encodable {
    struct Zip: Encodable {
        var name: String
        var url: String
        var sha256: String
        var size: Int
    }
    var bundleID: String
    var version: String
    var minimumSystemVersion: String
    var published: String
    var notes: String
    var zip: Zip
}
let manifest = Manifest(
    bundleID: info["CFBundleIdentifier"] as? String ?? "",
    version: info["CFBundleShortVersionString"] as? String ?? "",
    minimumSystemVersion: info["LSMinimumSystemVersion"] as? String ?? "",
    published: published.string(from: Date()),
    notes: notes,
    zip: .init(name: URL(fileURLWithPath: zipPath).lastPathComponent, url: url,
               sha256: SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined(), size: zip.count))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let payload = try encoder.encode(manifest)
let signature = try privateKey.signature(for: payload)

// Check it the way the app will, with the keys it ships.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = (try? String(contentsOf: root.appendingPathComponent("Sources/OatcakeCore/Update.swift"), encoding: .utf8)) ?? ""
let shipped = source.matches(of: #/"([A-Za-z0-9+/]{43}=)"/#).map { String($0.output.1) }
let accepted = shipped.contains { key in
    guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
    return publicKey.isValidSignature(signature, for: payload)
}
if !accepted { fail("OATCAKE_UPDATE_KEY doesn't match any public key in Update.publicKeys.") }

let envelope = try encoder.encode(["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()])
FileHandle.standardOutput.write(envelope + Data("\n".utf8))
