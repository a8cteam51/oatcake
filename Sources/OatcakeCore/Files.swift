import Foundation

/// Where Oatcake keeps its own data. Meetings live wherever Settings › Meetings folder says.
public enum Paths {
    /// OATCAKE_DATA_DIR points a development copy at another folder, so it leaves your own data alone.
    public static let data = ProcessInfo.processInfo.environment["OATCAKE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oatcake", isDirectory: true)
    public static let models = data.appendingPathComponent("models", isDirectory: true)
    public static let recordings = data.appendingPathComponent("recordings", isDirectory: true)
    public static let voiceprints = data.appendingPathComponent("voiceprints.json")
    public static let config = data.appendingPathComponent("config.json")
    public static let calendar = data.appendingPathComponent("calendar.json")
    public static let updateLog = data.appendingPathComponent("update.log")
}

public struct OatcakeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension FileManager {
    func exists(_ url: URL) -> Bool { fileExists(atPath: url.path) }

    func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}

/**
 * Replaces a file in one step: readers never see it half-written, and a crash mid-write leaves the
 * old file. The temporary file gets a random name and must not already exist, so a symlink planted
 * next to the target (say, in a synced Meetings folder) can't redirect the write elsewhere.
 */
public func writeAtomic(_ url: URL, _ data: Data, permissions: Int? = nil) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(12)).tmp")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions ?? 0o644))
    guard fd >= 0 else { throw OatcakeError("Couldn't write \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(tmp.path, url.path) == 0 else { throw OatcakeError("Couldn't save \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

public func writeAtomic(_ url: URL, _ text: String, permissions: Int? = nil) throws {
    try writeAtomic(url, Data(text.utf8), permissions: permissions)
}

/// Resolves a path relative to `root`, refusing anything that escapes it.
public func resolveInside(_ root: URL, _ rel: String) throws -> URL {
    let base = root.standardizedFileURL
    let full = (rel.isEmpty ? base : base.appendingPathComponent(rel)).standardizedFileURL
    if full.path != base.path && !full.path.hasPrefix(base.path + "/") {
        throw OatcakeError("Path is outside the Meetings folder: \(rel)")
    }
    return full
}

/// The path of `url` relative to `root` ("" for root itself).
func relativePath(_ url: URL, to root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == base { return "" }
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
}

// MARK: - JSON

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

public func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// nil when the file is missing or can't be read as T.
public func tryJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    try? readJSON(type, url)
}

public func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
}

public func readText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

extension String {
    /// Whitespace and newlines trimmed from both ends.
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Dates

/// Dates in folder names, to-dos and the windows are Gregorian, whatever calendar the Mac is set to
/// (a Buddhist or Japanese calendar counts years differently, and some have a thirteenth month).
public var gregorian: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

/// "2026-11-05T14:00:02.682Z", the way the Electron version wrote times.
public func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }

/// Reads ISO 8601 times with or without fractional seconds.
public func parseISO(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    return isoFormatter.date(from: string) ?? isoPlain.date(from: string)
}
