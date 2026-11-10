// API keys and the calendar's private address, typed into Settings, kept in your login Keychain.
// The window can save one and learn whether one is saved, but never reads one back.

import CommonCrypto
import Foundation
import Security

public enum SecretName: String, CaseIterable, Sendable {
    case anthropic, openai, calendar

    /// One already in the environment when Oatcake started (e.g. from your shell) is the fallback.
    var environmentVariable: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OATCAKE_OPENAI_API_KEY"
        case .calendar: "OATCAKE_CALENDAR_URL"
        }
    }
}

public enum Secrets {
    static let service = "Oatcake"

    /// The saved value, or the one inherited from the environment, or "".
    public static func get(_ name: SecretName) -> String {
        if let saved = keychainRead(account: name.rawValue), !saved.isEmpty { return saved }
        return ProcessInfo.processInfo.environment[name.environmentVariable] ?? ""
    }

    /// What Settings shows: whether one is saved, and enough to recognise it.
    public static func describe(_ name: SecretName) -> (saved: Bool, hint: String) {
        guard let value = keychainRead(account: name.rawValue), !value.isEmpty else {
            let inherited = ProcessInfo.processInfo.environment[name.environmentVariable]
            return (false, inherited != nil ? "Using the \(name == .calendar ? "address" : "key") from your shell" : "")
        }
        if name == .calendar {
            let host = URL(string: value.replacingOccurrences(of: "webcal:", with: "https:", options: [.anchored, .caseInsensitive]))?.host
            return (true, host.map { "Saved · \($0)" } ?? "Saved")
        }
        return (true, "Saved · ends in \(value.suffix(4))")
    }

    /// Saves a secret, or removes it when the value is blank.
    public static func set(_ name: SecretName, _ value: String) throws {
        let clean = value.trimmed
        guard !clean.isEmpty else {
            keychainDelete(account: name.rawValue)
            return
        }
        // Changed in place, and only added when there's none yet: a save that fails keeps the old value.
        let item = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name.rawValue] as [CFString: Any]
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData: Data(clean.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging([kSecAttrLabel: "Oatcake: \(name.rawValue)", kSecValueData: Data(clean.utf8)]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OatcakeError("Couldn't save to the Keychain (\(status)).") }
    }

    static func keychainRead(account: String, service: String = service) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func keychainDelete(account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    // MARK: - From the Electron version

    /// The Electron version kept secrets in secrets.json, encrypted with Chromium's OSCrypt under a
    /// key in the Keychain ("Oatcake Safe Storage"). They move into the Keychain once, and the file
    /// goes. A secret that can't be read, or can't be saved, is left in the file for the next launch.
    public static func migrateFromElectron() {
        let file = Paths.data.appendingPathComponent("secrets.json")
        guard let stored = tryJSON([String: String].self, file), !stored.isEmpty else { return }
        guard let password = keychainRead(account: "Oatcake Key", service: "Oatcake Safe Storage") else { return }
        var remaining = stored
        for (key, value) in stored {
            guard let name = SecretName(rawValue: key), let data = Data(base64Encoded: value),
                  let plain = decryptOSCrypt(data, password: password) else { continue }
            if keychainRead(account: name.rawValue) == nil {
                do { try set(name, plain) } catch { continue }
            }
            remaining.removeValue(forKey: key)
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let text = try? encodeJSON(remaining) {
            try? writeAtomic(file, text, permissions: 0o600)
        }
    }

    /// Chromium's macOS scheme: "v10" + AES-128-CBC (IV of 16 spaces) under PBKDF2-SHA1(password, "saltysalt", 1003).
    static func decryptOSCrypt(_ data: Data, password: String) -> String? {
        guard data.starts(with: Data("v10".utf8)) else { return nil }
        let body = data.dropFirst(3)
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw), salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + 16)
        var moved = 0
        let status = body.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, body.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: out[..<moved], encoding: .utf8)
    }
}
