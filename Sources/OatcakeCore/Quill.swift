// Imports Quill's backup: a .zip holding quill.db (SQLite) and a meetings/ folder with each meeting's
// recordings. Each meeting becomes a meeting folder under a "Quill" folder: transcript.md (from
// Quill's speaker-labelled transcript), summary.md (Quill's notes, when it made any), audio.m4a (the
// combined recording; the separate mic and system tracks are left out) and meeting.json. Meetings that
// share a title are grouped in a subfolder. A meeting already in the Meetings folder is skipped.

import Foundation

public let quillFolder = "Quill"

private struct QuillMeeting: Decodable {
    var id: String
    var title: String?
    /// Milliseconds since 1970.
    var start: Double?
    var end: Double?
    /// The meeting's folder under meetings/ in the backup.
    var folder: String?
    var transcript: String?
}

private struct QuillNote: Decodable {
    var meeting: String
    var title: String?
    var body: String?
}

private struct QuillSpeaker: Decodable {
    var meeting: String
    var speaker: String
    var name: String
}

private struct QuillTranscript: Decodable {
    struct Block: Decodable {
        var from: Double
        var to: Double
        var text: String
        var source: String?
        var speaker_id: String?
    }
    var blocks: [Block]
}

private func query<T: Decodable>(_ db: URL, _ sql: String) throws -> [T] {
    let out = try runCapturing("/usr/bin/sqlite3", ["-readonly", "-json", db.path, sql])
    // No rows prints nothing at all.
    return out.trimmed.isEmpty ? [] : try JSONDecoder().decode([T].self, from: Data(out.utf8))
}

/**
 * Quill's transcript as Oatcake's: your microphone is you, the call side is the name Quill matched
 * to each voice, or "Voice 1", "Voice 2"… Times count from the start of the recording.
 */
func quillTranscript(_ json: String, start: Double, me: String, names: [String: String]) -> (markdown: String, participants: [String]) {
    let blocks = (try? JSONDecoder().decode(QuillTranscript.self, from: Data(json.utf8)))?.blocks ?? []
    var voices: [String] = []
    let lines = blocks.compactMap { b -> Line? in
        let text = b.text.trimmed
        guard !text.isEmpty else { return nil }
        let id = b.speaker_id ?? ""
        let speaker: String
        if b.source == "mic" {
            speaker = me
        } else if let name = names[id] {
            speaker = name
        } else {
            if !voices.contains(id) { voices.append(id) }
            speaker = "Voice \(voices.firstIndex(of: id)! + 1)"
        }
        return Line(speaker: speaker, start: max(0, (b.from - start) / 1000), end: max(0, (b.to - start) / 1000), text: text)
    }
    var participants: [String] = []
    // Only the "Voice n" labels made up above are left out, not a name Quill matched that happens to look like one.
    let unnamed = Set(voices.indices.map { "Voice \($0 + 1)" })
    for l in lines where !unnamed.contains(l.speaker) && !participants.contains(l.speaker) { participants.append(l.speaker) }
    let markdown = mergeRuns(lines).map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n"
    return (markdown, participants)
}

/// Quill's notes on one meeting, one after another. Its minute markers ("#### 2m") are dropped, and
/// the HTML entities some notes carry are turned back into characters.
func quillSummary(_ notes: [(title: String?, body: String?)]) -> String {
    let parts = notes.compactMap { n -> String? in
        let body = (n.body ?? "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+\d+m\s*$\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmed
        guard !body.isEmpty else { return nil }
        let title = (n.title ?? "").trimmed
        return notes.count > 1 && !title.isEmpty ? "# \(title)\n\n\(body)" : body
    }
    return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
}

public func importQuill(_ file: URL, into root: URL, me: String, progress: ImportProgress = { _, _ in }) throws -> ImportResult {
    guard file.pathExtension.lowercased() == "zip" else { throw OatcakeError("Pick the .zip that Quill’s backup made.") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-quill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let db = tmp.appendingPathComponent("quill.db")
    // The database now; each meeting's combined recording as it's imported (the mic and system tracks are left in the zip).
    _ = try? runCapturing("/usr/bin/unzip", ["-qq", "-o", file.path, "quill.db", "-d", tmp.path])
    guard FileManager.default.exists(db) else { throw OatcakeError("That .zip has no quill.db in it. Is it the backup Quill made?") }

    let meetings: [QuillMeeting]
    let notes: [QuillNote]
    let speakers: [QuillSpeaker]
    do {
        meetings = try query(db, """
            SELECT id, coalesce(nullif(trim(manualTitle), ''), nullif(trim(title), ''), nullif(trim(eventTitle), '')) AS title,
                   iif(typeof(start) IN ('integer', 'real'), start, NULL) AS start, iif(typeof("end") IN ('integer', 'real'), "end", NULL) AS "end",
                   folder, audio_transcript AS transcript
            FROM Meeting WHERE deleteDate IS NULL AND coalesce(hidden, 0) = 0 ORDER BY start
            """)
        notes = try query(db, "SELECT meeting_id AS meeting, title, body FROM Note ORDER BY createdAt")
        speakers = try query(db, """
            SELECT cm.meeting_id AS meeting, cm.speaker_id AS speaker, coalesce(nullif(trim(c.name), ''), nullif(trim(cm.suggested_name), '')) AS name
            FROM ContactMeeting cm LEFT JOIN Contact c ON c.id = cm.contact_id
            WHERE coalesce(nullif(trim(c.name), ''), nullif(trim(cm.suggested_name), '')) IS NOT NULL
            """)
    } catch {
        throw OatcakeError("Couldn’t read Quill’s database (\(error.localizedDescription)). Is it a backup from a recent Quill?")
    }
    let notesOf = Dictionary(grouping: notes, by: \.meeting)
    let namesOf = Dictionary(grouping: speakers, by: \.meeting).mapValues { Dictionary($0.map { ($0.speaker, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var known = knownIds(root, key: "quillMeeting")
    let titleOf = { (m: QuillMeeting) in m.title ?? "Untitled" }
    var titles: [String: Int] = [:]
    for m in meetings { titles[titleOf(m), default: 0] += 1 }

    var result = ImportResult(folder: quillFolder)
    progress(0, meetings.count)
    for (i, m) in meetings.enumerated() {
        defer { progress(i + 1, meetings.count) }
        let id = m.id.lowercased()
        guard id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil, let start = m.start else {
            result.unreadable += 1
            continue
        }
        if known.contains(id) {
            result.skipped += 1
            continue
        }
        let title = titleOf(m)
        let (transcript, participants) = quillTranscript(m.transcript ?? "", start: start, me: me, names: namesOf[m.id] ?? [:])
        struct Meta: Encodable {
            var title: String
            var startedAt: String
            var endedAt: String?
            var participants: [String]
            var source = "quill"
            var quillMeeting: String
        }
        var files = ["transcript.md": transcript,
                     "meeting.json": try encodeJSON(Meta(title: title, startedAt: isoString(Date(timeIntervalSince1970: start / 1000)),
                                                         endedAt: m.end.map { isoString(Date(timeIntervalSince1970: $0 / 1000)) },
                                                         participants: participants, quillMeeting: id)) + "\n"]
        let summary = quillSummary((notesOf[m.id] ?? []).map { ($0.title, $0.body) })
        if !summary.isEmpty { files["summary.md"] = summary }
        // The folder name comes from the backup: only a plain name is followed.
        var moving: [String: URL] = [:]
        if let folder = m.folder, !folder.isEmpty, !folder.contains("/"), !folder.hasPrefix("."),
           // A meeting without a recording is fine (unzip exits non-zero when nothing matches).
           (try? runCapturing("/usr/bin/unzip", ["-qq", "-o", file.path, "meetings/\(folder)/*-combined.m4a", "-d", tmp.path])) != nil,
           // Quill names the finished recording "<id>-FINAL-<start>-<end>-combined.m4a": that one if there are
           // several, else the first by name, so the pick doesn't depend on the order the folder lists in.
           let found = try? FileManager.default.contentsOfDirectory(at: tmp.appendingPathComponent("meetings/\(folder)"), includingPropertiesForKeys: nil)
               .filter({ $0.lastPathComponent.hasSuffix("-combined.m4a") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
           let audio = found.first(where: { $0.lastPathComponent.contains("-FINAL-") }) ?? found.first {
            moving["audio.m4a"] = audio
        }
        let series = (titles[title] ?? 0) > 1 ? seriesFolder(title) : ""
        try writeImported(root, base: [quillFolder, series].filter { !$0.isEmpty }.joined(separator: "/"),
                          title: title, startedAt: Date(timeIntervalSince1970: start / 1000), files: files, moving: moving)
        known.insert(id)
        result.imported += 1
    }
    return result
}
