// Reading the meeting files for the rendered views. Each format Oatcake has written, plus Granola's
// imports, is understood.

import Foundation

/// "0:20" → "00:20", so every timestamp reads the same way.
public func padStamp(_ stamp: String) -> String {
    stamp.range(of: #"^\d:\d\d$"#, options: .regularExpression) != nil ? "0" + stamp : stamp
}

/// "12:34" or "1:02:03" → seconds.
public func seconds(_ stamp: String) -> Double {
    let p = stamp.split(separator: ":").map { Double($0) ?? 0 }
    return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p.count == 2 ? p[0] * 60 + p[1] : 0
}

/// "03:09", or "1:02:09" past an hour.
public func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    let mmss = String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    return s >= 3600 ? "\(s / 3600):\(mmss)" : mmss
}

public struct TranscriptLine: Equatable, Sendable {
    public var stamp: String
    public var at: Double
    public var speaker: String
    public var text: String
}

private let stampPattern = #"(\d{1,2}:\d\d(?::\d\d)?)"#
private let transcriptFormats: [NSRegularExpression] = [
    // **[12:34] Name:** text   (Oatcake)
    #"^\*\*\[\#(stampPattern)\]\s+(.+?):\*\*\s*(.*)$"#,
    // [12:34] **Name:** text
    #"^\[\#(stampPattern)\]\s+\*\*(.+?):\*\*\s*(.*)$"#,
    // [12:34] System audio (Name): text   /   [12:34] Microphone: text   (Granola)
    #"^\[\#(stampPattern)\]\s+([^:]{1,80}?):\s+(.*)$"#,
].map { try! NSRegularExpression(pattern: $0) }

func groups(_ match: NSTextCheckingResult, in text: String) -> [String?] {
    (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
}

func firstMatch(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
}

public func parseTranscript(_ markdown: String) -> [TranscriptLine] {
    markdown.components(separatedBy: "\n").compactMap { raw in
        let line = raw.trimmed
        for format in transcriptFormats {
            if let g = firstMatch(format, line), let stamp = g[1], let speaker = g[2] {
                let name = speaker.replacingOccurrences(of: #"^System audio \((.+)\)$"#, with: "$1", options: .regularExpression)
                return TranscriptLine(stamp: padStamp(stamp), at: seconds(stamp), speaker: name, text: g[3] ?? "")
            }
        }
        return nil
    }
}

public struct NoteLine: Equatable, Sendable {
    /// nil for a prep note written before the call.
    public var stamp: String?
    public var text: String
}

private let noteFormat = try! NSRegularExpression(pattern: #"^\s*[-*]\s+(?:\[\#(stampPattern)\]\s+)?(.*)$"#)

public func parseNotes(_ markdown: String) -> [NoteLine] {
    markdown.components(separatedBy: "\n").compactMap { line in
        guard let g = firstMatch(noteFormat, line), let text = g[2]?.trimmed, !text.isEmpty,
              text.range(of: #"^\*\*[^*]+:\*\*"#, options: .regularExpression) == nil else { return nil }
        return NoteLine(stamp: g[1].map(padStamp), text: text)
    }
}

public struct Todo: Equatable, Hashable, Sendable {
    /// Line number in todo.md, for ticking it off.
    public var line: Int
    public var done: Bool
    public var text: String
    public var owner: String
    public var due: String
    public var stamp: String
}

private let todoFormat = try! NSRegularExpression(pattern: #"^\s*[-*]\s+\[( |x|X)\]\s+(.*)$"#)
private let lonelyStamp = try! NSRegularExpression(pattern: #"^\[\#(stampPattern)\]$"#)

/// "- [ ] Task — Owner — due Fri, Oct 30 — [12:34]" (owner, due date and time optional).
public func parseTodos(_ markdown: String) -> [Todo] {
    markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
        guard let g = firstMatch(todoFormat, line), let box = g[1], let body = g[2] else { return nil }
        let pieces = body.replacingOccurrences(of: #"\s+—\s+"#, with: "\u{0}", options: .regularExpression).components(separatedBy: "\u{0}")
        var todo = Todo(line: index, done: box != " ", text: pieces[0], owner: "", due: "", stamp: "")
        for p in pieces.dropFirst() {
            if let stamp = firstMatch(lonelyStamp, p)?[1] ?? nil {
                todo.stamp = padStamp(stamp)
            } else if p.range(of: #"^due\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
                todo.due = p.replacingOccurrences(of: #"^due\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            } else {
                todo.owner = p
            }
        }
        return todo
    }
}

/// todo.md with one item ticked or unticked.
public func toggleTodo(_ markdown: String, line: Int) -> String {
    var lines = markdown.components(separatedBy: "\n")
    guard lines.indices.contains(line), let range = lines[line].range(of: #"\[( |x|X)\]"#, options: .regularExpression) else { return markdown }
    lines[line].replaceSubrange(range, with: lines[line][range] == "[ ]" ? "[x]" : "[ ]")
    return lines.joined(separator: "\n")
}

/**
 * A typed to-do in todo.md's form. " - " and " -- " count as the separator (an em dash is awkward
 * to type), and `owner` fills in when none is given: "Send the deck - due Fri, Nov 6" with owner
 * "Sam" becomes "Send the deck — Sam — due Fri, Nov 6".
 */
public func typedTodo(_ text: String, owner: String? = nil) -> String {
    var parts = text.trimmed.replacingOccurrences(of: #"\s+(?:—|--|-)\s+"#, with: "\u{0}", options: .regularExpression).components(separatedBy: "\u{0}")
    let isField = { (p: String) in
        p.range(of: #"^due\s"#, options: [.regularExpression, .caseInsensitive]) != nil
            || p.range(of: #"^\[\d{1,2}:\d\d(?::\d\d)?\]$"#, options: .regularExpression) != nil
    }
    let named = parts.dropFirst().contains { !isField($0) }
    if let owner, !owner.isEmpty, !named { parts.insert(owner, at: 1) }
    return parts.joined(separator: " — ")
}

/// todo.md with a new open to-do at the end.
public func addTodo(_ markdown: String, _ text: String) -> String {
    let base = markdown.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
    return "\(base.isEmpty ? "" : base + "\n")- [ ] \(text.trimmed)\n"
}

/// An item on the combined To-dos page.
public struct TodoItem: Identifiable, Equatable, Sendable {
    public var todo: Todo
    public var meeting: MeetingTodos
    public var dueDate: Date?
    public var id: String { "\(meeting.path):\(todo.line)" }

    public func isOverdue(today: Date = Calendar.current.startOfDay(for: Date())) -> Bool {
        !todo.done && dueDate.map { $0 < today } == true
    }
}

public func allTodoItems(_ meetings: [MeetingTodos]) -> [TodoItem] {
    meetings.flatMap { m in parseTodos(m.todo).map { TodoItem(todo: $0, meeting: m, dueDate: dueDate($0.due, meetingDate: m.startedAt)) } }
}

/**
 * "Fri, Oct 30" → a date. To-dos give no year, so it's the meeting's year, or the next one when that
 * would put it well before the meeting (a December call agreeing something for January).
 */
public func dueDate(_ due: String, meetingDate: Date? = nil) -> Date? {
    guard !due.trimmed.isEmpty else { return nil }
    let met = meetingDate ?? Date()
    let calendar = gregorian
    let text = due.replacingOccurrences(of: #"^[A-Za-z]+,\s*"#, with: "", options: .regularExpression).trimmed
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.isLenient = true
    let hasYear = text.range(of: #"\d{4}"#, options: .regularExpression) != nil
    var found: Date?
    let candidates = hasYear ? [text] : ["\(text) \(calendar.component(.year, from: met))"]
    for format in ["MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy", "d MMMM yyyy", "yyyy-MM-dd", "M/d/yyyy"] {
        formatter.dateFormat = format
        if let d = candidates.lazy.compactMap({ formatter.date(from: $0) }).first { found = d; break }
    }
    guard var date = found else { return nil }
    if !hasYear, date < met.addingTimeInterval(-60 * 86_400) { date = calendar.date(byAdding: .year, value: 1, to: date)! }
    return calendar.startOfDay(for: date)
}
