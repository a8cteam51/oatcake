import Foundation

/**
 * Prep notes written on New recording, kept until the call is recorded: you can write them hours
 * ahead, go and look at something else, and find them there when you come back. They're kept per
 * calendar event (one occurrence of it), or under "" for a recording that isn't from the calendar.
 * Once the call starts they become the first lines of its notes and are forgotten here.
 */
public enum PrepNotes {
    struct Entry: Codable, Equatable {
        var notes: [String]
        var savedAt: String
    }

    /// Prep for a call that never got recorded isn't kept for ever.
    static let keptFor: TimeInterval = 30 * 86_400

    public static func load(_ event: String?, from file: URL = Paths.prep) -> [String] {
        all(file)[event ?? ""]?.notes ?? []
    }

    /// Saving none forgets the event's prep.
    public static func save(_ event: String?, _ notes: [String], to file: URL = Paths.prep, now: Date = Date()) throws {
        var entries = all(file).filter { now.timeIntervalSince(parseISO($0.value.savedAt) ?? .distantPast) < keptFor }
        let kept = notes.map(\.trimmed).filter { !$0.isEmpty }
        entries[event ?? ""] = kept.isEmpty ? nil : Entry(notes: kept, savedAt: isoString(now))
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAtomic(file, try encodeJSON(entries) + "\n")
        }
    }

    private static func all(_ file: URL) -> [String: Entry] { tryJSON([String: Entry].self, file) ?? [:] }
}

/**
 * Typed or pasted text as prep notes, one per line: an agenda pasted from an email or a document
 * comes in as its points, without the bullets, numbers or tick boxes they were listed with.
 */
public func prepLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).compactMap { line in
        let point = line.replacingOccurrences(of: #"^\s*(?:(?:[-*•–—·▪◦‣]|\d{1,3}[.)])\s+)?(?:\[[ xX]?\]\s+)?"#, with: "", options: .regularExpression).trimmed
        return point.isEmpty ? nil : point
    }
}
