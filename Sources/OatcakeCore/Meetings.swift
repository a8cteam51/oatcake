// The Meetings folder on disk is the source of truth: a folder holding meeting.json is a meeting,
// any other folder is a folder you organise meetings into. Renames and moves here are plain
// filesystem renames, so Finder and the app stay in step.

import Foundation

public struct TreeNode: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Sendable { case folder, meeting }
    public var name: String
    /// Path relative to the Meetings folder ("" for the root).
    public var path: String
    public var kind: Kind
    public var children: [TreeNode] = []
    /// Meetings only, from meeting.json.
    public var title: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Imported from a Granola export.
    public var granola = false
    /// The summary's first line of prose.
    public var preview = ""
    public var id: String { path }

    public var subfolders: [TreeNode] { children.filter { $0.kind == .folder } }
    public var meetings: [TreeNode] { children.filter { $0.kind == .meeting } }

    public func find(_ path: String) -> TreeNode? {
        if self.path == path { return self }
        for child in children {
            if child.kind == .folder, path == child.path || path.hasPrefix(child.path + "/") { return child.find(path) }
            if child.path == path { return child }
        }
        return nil
    }

    /// Every meeting at any depth.
    public var allMeetings: [TreeNode] { kind == .meeting ? [self] : children.flatMap(\.allMeetings) }

    /// Every folder below this one, depth first.
    public var allFolders: [TreeNode] { subfolders.flatMap { [$0] + $0.allFolders } }
}

/// What meeting.json holds. Its other keys (granolaNote, recording) are kept when a meeting is retitled.
public struct MeetingMeta: Codable, Equatable, Sendable {
    public var title: String?
    public var startedAt: String?
    public var endedAt: String?
    public var participants: [String]?
    public var source: String?
    public init() {}
}

public struct MeetingFiles: Equatable, Sendable {
    public var summary: String
    public var transcript: String
    public var notes: String
    public var todo: String
    public var meta: MeetingMeta
}

/// A meeting that a search found.
public struct SearchHit: Equatable, Sendable {
    public var path: String
    /// The file the line below is from. nil when every word is in the meeting's title or folder.
    public var file: MeetingFile?
    /// The first line with one of the words, as plain text, cut to start near the word.
    public var line = ""
    /// That line's time in the transcript ("12:34"), when it has one.
    public var stamp: String?
}

public enum MeetingFile: String, CaseIterable, Sendable {
    case summary = "summary.md", transcript = "transcript.md", notes = "notes.md", todo = "todo.md"
}

public final class Meetings: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Previews are re-read only when summary.md changes, since the tree is rebuilt on every edit.
    private var previews: [String: (Date, String)] = [:]
    /// Each file's text for search, as written and with case and accents folded away. Kept the same way.
    private var texts: [String: (modified: Date, text: String, folded: String)] = [:]

    public init(root: URL) { self.root = root }

    private func preview(_ file: URL) -> String {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return "" }
        if let cached = lock.withLock({ previews[file.path] }), cached.0 == modified { return cached.1 }
        let text = String(previewOf(readText(file)).prefix(240))
        lock.withLock { previews[file.path] = (modified, text) }
        return text
    }

    public func tree() -> TreeNode {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        func walk(_ rel: String) -> TreeNode {
            let full = (try? resolveInside(root, rel)) ?? root
            let name = rel.isEmpty ? root.lastPathComponent : (rel as NSString).lastPathComponent
            let metaFile = full.appendingPathComponent("meeting.json")
            if !rel.isEmpty, fm.exists(metaFile) {
                // A hand-edited meeting.json shouldn't hide the meeting.
                let meta = tryJSON(MeetingMeta.self, metaFile)
                return TreeNode(name: name, path: rel, kind: .meeting, title: meta?.title, startedAt: parseISO(meta?.startedAt),
                                endedAt: parseISO(meta?.endedAt), granola: meta?.source == "granola",
                                preview: preview(full.appendingPathComponent("summary.md")))
            }
            let entries = (try? fm.contentsOfDirectory(at: full, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var children = entries.filter { fm.isDirectory($0) }.map { walk(rel.isEmpty ? $0.lastPathComponent : rel + "/" + $0.lastPathComponent) }
            // Folders first (A–Z), then meetings, newest first.
            children.sort {
                if $0.kind != $1.kind { return $0.kind == .folder }
                return $0.kind == .folder
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.name > $1.name
            }
            return TreeNode(name: name, path: rel, kind: .folder, children: children)
        }
        return walk("")
    }

    public func read(_ rel: String) throws -> MeetingFiles {
        let dir = try resolveInside(root, rel)
        return MeetingFiles(summary: readText(dir.appendingPathComponent("summary.md")),
                            transcript: readText(dir.appendingPathComponent("transcript.md")),
                            notes: readText(dir.appendingPathComponent("notes.md")),
                            todo: readText(dir.appendingPathComponent("todo.md")),
                            meta: tryJSON(MeetingMeta.self, dir.appendingPathComponent("meeting.json")) ?? MeetingMeta())
    }

    private func searchable(_ file: URL) -> (text: String, folded: String) {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return ("", "") }
        if let cached = lock.withLock({ texts[file.path] }), cached.modified == modified { return (cached.text, cached.folded) }
        let text = readText(file)
        let folded = foldedForSearch(text)
        lock.withLock { texts[file.path] = (modified, text, folded) }
        return (text, folded)
    }

    /**
     * The meetings that have every word of `query`, in the order given. A word can be in a meeting's
     * `label` (what the list shows for it: its title and folder) or anywhere in its summary, to-dos,
     * notes or transcript. Case and accents don't matter. A hit carries the first line with a word that
     * the label doesn't have, so the list can show why the meeting was found.
     */
    public func search(_ query: String, in meetings: [(path: String, label: String)]) -> [SearchHit] {
        let words = foldedForSearch(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let order: [MeetingFile] = [.summary, .todo, .notes, .transcript]
        return meetings.compactMap { meeting in
            guard let dir = try? resolveInside(root, meeting.path) else { return nil }
            let label = foldedForSearch(meeting.label)
            let files = order.map { ($0, searchable(dir.appendingPathComponent($0.rawValue))) }
            guard words.allSatisfy({ w in label.contains(w) || files.contains { $0.1.folded.contains(w) } }) else { return nil }
            let wanted = words.filter { !label.contains($0) }
            guard !wanted.isEmpty else { return SearchHit(path: meeting.path) }
            for (file, content) in files where wanted.contains(where: { content.folded.contains($0) }) {
                for raw in content.text.components(separatedBy: "\n") {
                    let folded = foldedForSearch(raw)
                    guard let word = wanted.first(where: { folded.contains($0) }) else { continue }
                    let plain = plainLine(raw)
                    guard file == .transcript else { return SearchHit(path: meeting.path, file: file, line: excerpt(plain, around: word)) }
                    // A transcript line keeps who said it, however far into it the word is.
                    var line = excerpt(plain, around: word)
                    if let said = firstMatch(transcriptSpeaker, plain), let whole = said[0], let speaker = said[1] {
                        line = "\(speaker): \(excerpt(String(plain.dropFirst(whole.count)), around: word))"
                    }
                    return SearchHit(path: meeting.path, file: file, line: line, stamp: firstMatch(transcriptStamp, raw)?[1] ?? nil)
                }
            }
            return SearchHit(path: meeting.path)
        }
    }

    /// Saves an edit made in the app. Only the meeting's Markdown files can be written.
    public func write(_ rel: String, _ file: MeetingFile, _ content: String) throws {
        let target = try resolveInside(root, rel).appendingPathComponent(file.rawValue)
        if content.isEmpty && !FileManager.default.exists(target) { return }
        try writeAtomic(target, content)
    }

    private func checkName(_ name: String) throws -> String {
        let clean = name.trimmed
        if clean.isEmpty || clean == "." || clean == ".." || clean.contains("/") || clean.contains(":") {
            throw OatcakeError("Names can't be empty or contain / or :")
        }
        return clean
    }

    /// Refuses to overwrite, unless `self` is the item already there (a capitalisation-only rename on a case-insensitive disk).
    private func ensureFree(_ target: URL, self source: URL? = nil) throws {
        let fm = FileManager.default
        guard fm.exists(target) else { return }
        if let source, let a = (try? fm.attributesOfItem(atPath: target.path))?[.systemFileNumber] as? Int,
           let b = (try? fm.attributesOfItem(atPath: source.path))?[.systemFileNumber] as? Int, a == b { return }
        throw OatcakeError("Something called “\(target.lastPathComponent)” is already there")
    }

    /// Renames in place; returns the new relative path.
    @discardableResult
    public func rename(_ rel: String, to newName: String) throws -> String {
        guard !rel.isEmpty else { throw OatcakeError("The Meetings folder itself can't be renamed here") }
        let from = try resolveInside(root, rel)
        let parent = (rel as NSString).deletingLastPathComponent
        let name = try checkName(newName)
        let to = try resolveInside(root, parent.isEmpty ? name : parent + "/" + name)
        if from.path == to.path { return rel }
        try ensureFree(to, self: from)
        try FileManager.default.moveItem(at: from, to: to)
        return relativePath(to, to: root)
    }

    /// Moves into another folder; returns the new relative path.
    @discardableResult
    public func move(_ rel: String, into folder: String) throws -> String {
        let from = try resolveInside(root, rel)
        let name = (rel as NSString).lastPathComponent
        let to = try resolveInside(root, folder.isEmpty ? name : folder + "/" + name)
        if to.path == from.path { return rel }
        if to.path.hasPrefix(from.path + "/") { throw OatcakeError("A folder can't go inside itself") }
        try ensureFree(to)
        try FileManager.default.moveItem(at: from, to: to)
        return relativePath(to, to: root)
    }

    /**
     * Gives a meeting a new title: in meeting.json (its other keys are kept) and in its folder's name,
     * which keeps its date. Returns the meeting's path afterwards. When a folder with the new name is
     * already there, only the title changes.
     */
    @discardableResult
    public func retitle(_ rel: String, to title: String) throws -> String {
        let clean = title.trimmed
        guard !clean.isEmpty else { throw OatcakeError("Give the meeting a title") }
        guard !rel.isEmpty else { throw OatcakeError("That isn't a meeting") }
        let file = try resolveInside(root, rel).appendingPathComponent("meeting.json")
        guard let data = try? Data(contentsOf: file), var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OatcakeError("This meeting's details (meeting.json) can't be read")
        }
        meta["title"] = clean
        let written = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeAtomic(file, written + Data("\n".utf8))
        let name = (rel as NSString).lastPathComponent
        guard let date = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, options: .regularExpression) else { return rel }
        return (try? rename(rel, to: String(name[date]) + folderSafe(clean))) ?? rel
    }

    @discardableResult
    public func createFolder(in parent: String, named name: String) throws -> String {
        let clean = try checkName(name)
        let target = try resolveInside(root, parent.isEmpty ? clean : parent + "/" + clean)
        try ensureFree(target)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return relativePath(target, to: root)
    }

    public func trash(_ rel: String) throws {
        guard !rel.isEmpty else { throw OatcakeError("The Meetings folder itself can't be moved to the Trash") }
        try FileManager.default.trashItem(at: try resolveInside(root, rel), resultingItemURL: nil)
    }

    /**
     * The folder a calendar event's recording goes in: the folder named like the event (punctuation
     * ignored, so "Sam & Alex 1:1" finds "Sam & Alex 1-1"), by its own name or its whole path. With no
     * such folder, it goes where the latest meeting of the same name is (a "Weekly sync" kept in
     * Team stays in Team). Failing that, a recurring event gets a new top-level folder named after
     * it, and a one-off goes at the top level.
     */
    public func folderForEvent(title: String, recurring: Bool) throws -> String {
        let tree = tree()
        if let match = matchingFolder(title, in: tree) { return match }
        if let earlier = latestMeeting(titled: title, in: tree) { return (earlier.path as NSString).deletingLastPathComponent }
        if !recurring { return "" }
        let name = safeName(title).isEmpty ? "Calls" : safeName(title)
        return FileManager.default.exists(try resolveInside(root, name)) ? name : try createFolder(in: "", named: name)
    }

    /// Every meeting's todo.md, for the combined To-dos page. Meetings without one are left out.
    public func allTodos() -> [MeetingTodos] {
        var out: [MeetingTodos] = []
        for meeting in tree().allMeetings {
            guard let file = try? resolveInside(root, meeting.path).appendingPathComponent("todo.md"),
                  FileManager.default.exists(file) else { continue }
            out.append(MeetingTodos(path: meeting.path, title: meeting.title ?? meeting.name, startedAt: meeting.startedAt, todo: readText(file)))
        }
        // To-dos added on the To-dos page itself live in the Meetings folder's own todo.md.
        let own = root.appendingPathComponent("todo.md")
        if FileManager.default.exists(own) { out.insert(MeetingTodos(path: "", title: "To-dos", startedAt: nil, todo: readText(own)), at: 0) }
        return out
    }
}

public struct MeetingTodos: Equatable, Sendable {
    /// The meeting, relative to the Meetings folder; "" for the Meetings folder's own list.
    public var path: String
    public var title: String
    public var startedAt: Date?
    /// todo.md's text.
    public var todo: String
}

/// The folder (by its own name, or its whole path) named like a title, ignoring punctuation.
/// A title that is all punctuation matches nothing.
public func matchingFolder(_ title: String, in tree: TreeNode) -> String? {
    let key = loose(title)
    guard !key.isEmpty else { return nil }
    let folders = tree.allFolders.map(\.path)
    return folders.first { loose(($0 as NSString).lastPathComponent) == key } ?? folders.first { loose($0) == key }
}

/// The most recent meeting with this title, compared as loosely as folder names are.
public func latestMeeting(titled title: String, in tree: TreeNode) -> TreeNode? {
    let key = loose(title)
    guard !key.isEmpty else { return nil }
    let named = { (m: TreeNode) in m.title ?? m.name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, with: "", options: .regularExpression) }
    return tree.allMeetings.filter { loose(named($0)) == key }
        .max { ($0.startedAt ?? .distantPast, $0.name) < ($1.startedAt ?? .distantPast, $1.name) }
}

/// A meeting's folder name: "2026-11-05 1400 Weekly sync", in local time.
public func meetingFolderName(title: String, startedAt: Date) -> String {
    let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
    let stamp = String(format: "%04d-%02d-%02d %02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    let clean = folderSafe(title)
    return "\(stamp) \(clean.isEmpty ? "Call" : clean)"
}

/// A title as it can appear in a folder name: no "/", ":" or "\".
func folderSafe(_ title: String) -> String {
    title.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression).trimmed
}

/// A folder name made from free text such as an event title: no "/" or ":".
public func safeName(_ name: String) -> String {
    name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
}

/// Letters and digits only (any script), for matching names that differ only in punctuation.
public func loose(_ name: String) -> String {
    String(name.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(Character.init))
}

// MARK: - Reading meeting files

/**
 * Drops the block older meeting files open with: a "# Title" line followed by "- **Date:** …"
 * style metadata lines. The meeting view shows that information from meeting.json instead.
 */
public func stripHeader(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var i = 0
    while i < lines.count, lines[i].trimmed.isEmpty { i += 1 }
    guard i < lines.count, lines[i].range(of: #"^#\s"#, options: .regularExpression) != nil else { return markdown }
    i += 1
    while i < lines.count, lines[i].trimmed.isEmpty
        || lines[i].range(of: #"^\s*[-*]\s+\*\*[^*]+:\*\*"#, options: .regularExpression) != nil
        || lines[i].trimmed.range(of: #"^-{3,}$"#, options: .regularExpression) != nil {
        i += 1
    }
    return lines[i...].joined(separator: "\n")
}

/// A meeting file's content for reading: older files' title block and Granola's lone "## Summary" heading are dropped.
public func forReading(_ markdown: String) -> String {
    stripHeader(markdown).replacingOccurrences(of: #"^\s*#{1,3}\s+Summary\s*\n"#, with: "", options: [.regularExpression, .caseInsensitive])
}

/// The first line of prose in a summary, as plain text, for the meeting list.
public func previewOf(_ summary: String) -> String {
    for raw in stripHeader(summary).components(separatedBy: "\n") {
        let line = raw.trimmed
        if line.isEmpty || line.hasPrefix("#") || line.range(of: #"^-{3,}$"#, options: .regularExpression) != nil { continue }
        return plainLine(line)
    }
    return ""
}

/// One line of a meeting's Markdown as plain text, for the meeting list: no heading or list marker,
/// emphasis, link address or [mm:ss] time.
func plainLine(_ line: String) -> String {
    line.trimmed
        .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^[-*]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        // Granola escapes Markdown characters ("Updates \& Welcomes").
        .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!~&<>|])"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\s*\[\d{1,2}:\d\d(?::\d\d)?\]"#, with: "", options: .regularExpression)
        // A to-do that ended with its time ("… — Alex — [12:34]") is left with the dash before it.
        .replacingOccurrences(of: #"\s+[—–-]\s*$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
        .trimmed
}

/// Text with case and accents folded away, so a search for "cafe" finds "Café".
func foldedForSearch(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// The time a transcript line starts with: "**[12:34] Alex:** …".
private let transcriptStamp = try! NSRegularExpression(pattern: #"^\**\[(\d{1,2}:\d\d(?::\d\d)?)\]"#)

/// Who is speaking in a transcript line once it's plain text: "Alex Rivers: …".
private let transcriptSpeaker = try! NSRegularExpression(pattern: #"^([^:]{1,60}):\s+"#)

/// A long line cut to start a few words before `word` (already folded), so the word shows in the two
/// lines the meeting list has room for.
func excerpt(_ line: String, around word: String) -> String {
    let lead = 40
    let folded = foldedForSearch(line)
    guard let found = folded.range(of: word) else { return line }
    // Folding can change a line's length by a character or two; this only decides where the excerpt starts.
    let offset = folded.distance(from: folded.startIndex, to: found.lowerBound)
    guard offset > lead, offset < line.count else { return line }
    // Start at a word, not in the middle of one.
    let from = line.index(line.startIndex, offsetBy: offset - lead)
    let start = line[from...].firstIndex(of: " ").map { line.index(after: $0) } ?? from
    return "…" + line[start...]
}
