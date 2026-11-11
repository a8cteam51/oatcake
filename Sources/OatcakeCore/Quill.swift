// Imports Quill's backup: a .zip holding quill.db (SQLite) and a meetings/ folder with each meeting's
// recordings. Each meeting becomes a meeting folder under a "Quill" folder: transcript.md (from
// Quill's speaker-labelled transcript), summary.md (Quill's notes, when it made any), audio.m4a (the
// combined recording; the separate mic and system tracks are left out) and meeting.json. The
// recording always comes across, whatever Keep call audio is set to: the backup may be the only copy.
// Meetings that share a title are grouped in a subfolder. A meeting already in the Meetings folder
// is skipped, and so is one with nothing in it (no words, notes or recording).

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
        var from: Double?
        var to: Double?
        var text: String?
        var source: String?
        var speaker_id: String?
    }
    /// One that isn't in this shape is nil, so it's left out without taking the rest with it.
    struct Entry: Decodable {
        var block: Block?
        init(from decoder: Decoder) throws { block = try? Block(from: decoder) }
    }
    var blocks: [Entry]
}

private func query<T: Decodable>(_ db: URL, _ sql: String) throws -> [T] {
    // "-init /dev/null": without it sqlite3 reads your own ~/.sqliterc, and a setting there (".timer on",
    // ".echo on") adds lines to what it prints, which then isn't JSON.
    let out = try runCapturing("/usr/bin/sqlite3", ["-init", "/dev/null", "-readonly", "-json", db.path, sql])
    // No rows prints nothing at all.
    return out.trimmed.isEmpty ? [] : try JSONDecoder().decode([T].self, from: Data(out.utf8))
}

/**
 * Quill's transcript as Oatcake's: your microphone is you, the call side is the name Quill matched
 * to each voice, or "Voice 1", "Voice 2"… Times count from the start of the recording.
 */
func quillTranscript(_ json: String, start: Double, me: String, names: [String: String]) -> (markdown: String, participants: [String]) {
    // In the order things were said, whatever order the backup lists them in (kept as it is between equals).
    let blocks = ((try? JSONDecoder().decode(QuillTranscript.self, from: Data(json.utf8)))?.blocks ?? []).compactMap(\.block)
        .enumerated().sorted { ($0.element.from ?? 0, $0.offset) < ($1.element.from ?? 0, $1.offset) }.map(\.element)
    // A recording that began before the meeting's start time counts from its first line, so the lines
    // before the start keep their order and spacing rather than all landing on 00:00.
    let start = min(start, blocks.compactMap(\.from).min() ?? start)
    var voices: [String] = []
    let lines = blocks.compactMap { b -> Line? in
        guard let from = b.from, let text = b.text?.trimmed, !text.isEmpty else { return nil }
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
        return Line(speaker: speaker, start: max(0, (from - start) / 1000), end: max(0, ((b.to ?? from) - start) / 1000), text: text)
    }
    var participants: [String] = []
    // Only the "Voice n" labels made up above are left out, not a name Quill matched that happens to look like one.
    let unnamed = Set(voices.indices.map { "Voice \($0 + 1)" })
    for l in lines where !unnamed.contains(l.speaker) && !participants.contains(l.speaker) { participants.append(l.speaker) }
    let markdown = mergeRuns(lines).map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n"
    return (markdown, participants)
}

/// Quill's notes on one meeting, one after another. Its minute markers ("#### 2m", "#### 1h 2m") are
/// dropped (a heading of your own at another level is kept), and the HTML entities some notes carry
/// are turned back into characters.
func quillSummary(_ notes: [(title: String?, body: String?)]) -> String {
    let written = notes.compactMap { n -> (title: String, body: String)? in
        let body = (n.body ?? "")
            .replacingOccurrences(of: #"(?m)^####[ \t]+(?:\d+h(?:[ \t]*\d+m)?|\d+m)[ \t]*$\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmed
        return body.isEmpty ? nil : ((n.title ?? "").trimmed, body)
    }
    // Each note under its title when there are several. "##", as in Oatcake's own summaries: a summary
    // that starts with a "# " line is read as an older file's title block, and shown without it.
    let parts = written.map { written.count > 1 && !$0.title.isEmpty ? "## \($0.title)\n\n\($0.body)" : $0.body }
    return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
}

public func importQuill(_ file: URL, into root: URL, me: String, progress: ImportProgress = { _, _ in }) throws -> ImportResult {
    guard file.pathExtension.lowercased() == "zip" else { throw OatcakeError("Pick the .zip that Quill’s backup made.") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-quill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let db = tmp.appendingPathComponent("quill.db")
    // The database now; each meeting's combined recording as it's imported (the mic and system tracks are left in the zip).
    var unzipSaid = ""
    do {
        _ = try runCapturing("/usr/bin/unzip", ["-qq", "-o", file.path, "quill.db", "-d", tmp.path])
    } catch {
        unzipSaid = error.localizedDescription
    }
    guard FileManager.default.exists(db) else {
        // unzip says "filename not matched" when the archive is fine and the database isn't at its top level.
        throw OatcakeError(unzipSaid.isEmpty || unzipSaid.contains("not matched")
            ? "That .zip has no quill.db at its top level. Is it the backup as Quill made it?"
            : "That .zip couldn’t be opened. It may be incomplete or damaged.")
    }

    let meetings: [QuillMeeting]
    let notes: [QuillNote]
    let speakers: [QuillSpeaker]
    do {
        meetings = try query(db, """
            SELECT CAST(id AS TEXT) AS id, coalesce(nullif(trim(manualTitle), ''), nullif(trim(title), ''), nullif(trim(eventTitle), '')) AS title,
                   iif(typeof(start) IN ('integer', 'real'), start, NULL) AS start, iif(typeof("end") IN ('integer', 'real'), "end", NULL) AS "end",
                   folder, audio_transcript AS transcript
            FROM Meeting WHERE id IS NOT NULL AND deleteDate IS NULL AND coalesce(hidden, 0) = 0 ORDER BY start
            """)
        // A note or a voice that belongs to no meeting is left out here: one such row would otherwise stop the whole import.
        notes = try query(db, "SELECT CAST(meeting_id AS TEXT) AS meeting, title, body FROM Note WHERE meeting_id IS NOT NULL ORDER BY createdAt")
        speakers = try query(db, """
            SELECT CAST(cm.meeting_id AS TEXT) AS meeting, CAST(cm.speaker_id AS TEXT) AS speaker, coalesce(nullif(trim(c.name), ''), nullif(trim(cm.suggested_name), '')) AS name
            FROM ContactMeeting cm LEFT JOIN Contact c ON c.id = cm.contact_id
            WHERE cm.meeting_id IS NOT NULL AND cm.speaker_id IS NOT NULL
              AND coalesce(nullif(trim(c.name), ''), nullif(trim(cm.suggested_name), '')) IS NOT NULL
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
    // Why the first meeting that couldn't be written couldn't be.
    var failure: Error?
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
        // A meeting that can't be written (a title too long for a folder name, say) is counted and passed
        // over: the ones after it still come in, on this run and the next.
        guard let meta = try? encodeJSON(Meta(title: title, startedAt: isoString(Date(timeIntervalSince1970: start / 1000)),
                                              endedAt: m.end.map { isoString(Date(timeIntervalSince1970: $0 / 1000)) },
                                              participants: participants, quillMeeting: id)) else {
            result.unreadable += 1
            continue
        }
        var files = ["transcript.md": transcript, "meeting.json": meta + "\n"]
        let summary = quillSummary((notesOf[m.id] ?? []).map { ($0.title, $0.body) })
        if !summary.isEmpty { files["summary.md"] = summary }
        // The folder name comes from the backup: only a plain name is followed.
        var moving: [String: URL] = [:]
        if let folder = m.folder, !folder.isEmpty, !folder.contains("/"), !folder.hasPrefix(".") {
            // What's there afterwards is the test, not unzip's exit status: that's non-zero when nothing
            // matches (a meeting without a recording) and also after a mere warning with the file extracted.
            _ = try? runCapturing("/usr/bin/unzip", ["-qq", "-o", file.path, "meetings/\(folder)/*-combined.m4a", "-d", tmp.path])
            // Quill names the finished recording "<id>-FINAL-<start>-<end>-combined.m4a": that one if there are
            // several, else the first by name, so the pick doesn't depend on the order the folder lists in.
            let found = ((try? FileManager.default.contentsOfDirectory(at: tmp.appendingPathComponent("meetings/\(folder)"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("-combined.m4a") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let audio = found.first(where: { $0.lastPathComponent.contains("-FINAL-") }) ?? found.first { moving["audio.m4a"] = audio }
        }
        // A row with nothing to show for it (an event Quill listed and never recorded) isn't a meeting.
        if transcript.trimmed.isEmpty, summary.isEmpty, moving.isEmpty { continue }
        let series = (titles[title] ?? 0) > 1 ? seriesFolder(title) : ""
        do {
            try writeImported(root, base: [quillFolder, series].filter { !$0.isEmpty }.joined(separator: "/"),
                              title: title, startedAt: Date(timeIntervalSince1970: start / 1000), files: files, moving: moving)
        } catch {
            if failure == nil { failure = error }
            result.unreadable += 1
            continue
        }
        known.insert(id)
        result.imported += 1
    }
    // Nothing could be written at all (no room, or the Meetings folder can't be written to): say why.
    if result.imported == 0, result.skipped == 0, let failure { throw failure }
    return result
}
