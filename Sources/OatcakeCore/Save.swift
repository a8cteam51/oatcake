import Foundation

/// What the user decided for one speaker in review.
public enum Decision: Sendable, Equatable {
    case name(String)
    case merge(into: String)
    case mixed
    case ignore
}

/// A voiceprint needs this much of one person's speech to be worth keeping.
private let minVoiceprintSeconds = 30.0

/// "Voice 1", "Voice 2"… in the order review lists them (most talking first).
public func voiceLabel(_ analysis: Analysis, _ id: String) -> String {
    "Voice \((analysis.speakers.firstIndex { $0.id == id } ?? -1) + 1)"
}

public func loadAnalysis(_ rec: Recording) throws -> Analysis {
    try readJSON(Analysis.self, rec.dir.appendingPathComponent("analysis.json"))
}

public struct SavedMeeting: Sendable {
    /// The meeting's folder, relative to the Meetings folder.
    public var path: String
    /// Why the summary couldn't be written (the meeting was saved without one), if it couldn't.
    public var summaryError: String?
}

/**
 * Writes the meeting folder (summary.md, transcript.md, notes.md, todo.md, meeting.json) into
 * `folder` (relative to the Meetings folder) and saves confirmed voiceprints. When the summary model
 * can't be reached, everything else is still saved, and the meeting offers to write its summary
 * later (writeSummary), so nothing from the call waits on the model.
 */
public func saveMeeting(_ config: Config, _ rec: Recording, decisions: [String: Decision], folder: String,
                        onStep: (String) -> Void) async throws -> SavedMeeting {
    let analysis = try loadAnalysis(rec)
    let notes = Recordings.loadNotes(rec.id)

    /// The decision a voice ends up with once merges are followed (nil for your microphone).
    func settled(_ id: String, _ seen: Set<String> = []) -> (id: String, decision: Decision?)? {
        if id == me { return nil }
        let d = decisions[id]
        if case .merge(let into) = d, !seen.contains(id) { return settled(into, seen.union([id])) }
        return (id, d)
    }
    func nameOf(_ id: String) -> String? {
        guard let s = settled(id) else { return config.myName }
        switch s.decision {
        case .ignore: return nil
        case .mixed: return "Several people"
        case .name(let name) where !name.trimmed.isEmpty: return name.trimmed
        default:
            // Unnamed, or (shouldn't happen) no decision at all: keep the lines under a neutral label.
            return analysis.speakers.contains { $0.id == s.id } ? voiceLabel(analysis, s.id) : "Call audio"
        }
    }
    /// Only a name typed or accepted in review is worth remembering: not "Voice 2", "Several people" or you.
    func rememberedName(_ id: String) -> String? {
        if case .name(let name)? = settled(id)?.decision, !name.trimmed.isEmpty { return name.trimmed }
        return nil
    }

    let named = analysis.lines.compactMap { line -> Line? in
        nameOf(line.speaker).map { Line(speaker: $0, start: line.start, end: line.end, text: line.text) }
    }
    let paragraphs = mergeRuns(named)
    var participants: [String] = []
    for name in [config.myName] + paragraphs.map(\.speaker) where name != "Several people" && !participants.contains(name) {
        participants.append(name)
    }
    let transcript = paragraphs.map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n"

    onStep("Writing the summary")
    var summary = "", todo = "", summaryError: String?
    do {
        (summary, todo) = try await summarise(config, title: analysis.title, participants: participants, notes: notes, transcript: transcript)
    } catch {
        summaryError = error.localizedDescription
    }

    let startedAt = parseISO(analysis.startedAt) ?? rec.startedAt
    let name = meetingFolderName(title: analysis.title, startedAt: startedAt)
    // Another call with the same title in the same minute keeps its folder, and this one is numbered.
    // Saving this recording again (after a failure) goes back into its own folder.
    var outRel = folder.isEmpty ? name : folder + "/" + name
    var out = try resolveInside(config.meetingsRoot, outRel)
    var number = 2
    while let other = savedRecording(out), other != rec.id {
        outRel = (folder.isEmpty ? name : folder + "/" + name) + " (\(number))"
        out = try resolveInside(config.meetingsRoot, outRel)
        number += 1
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try transcript.write(to: out.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    if summaryError == nil { try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
    if !todo.isEmpty { try todo.write(to: out.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8) }
    if !notes.isEmpty { try notesMarkdown(notes).write(to: out.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
    struct Meta: Encodable {
        var title: String
        var startedAt: String
        var endedAt: String
        var participants: [String]
        var recording: String
    }
    try (try encodeJSON(Meta(title: analysis.title, startedAt: analysis.startedAt, endedAt: analysis.endedAt,
                             participants: participants, recording: rec.id)) + "\n")
        .write(to: out.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

    // Only now the meeting is written, so a failed summary that's retried doesn't add the same voices twice.
    // Fingerprints from another model (an analysis made by the Electron version) aren't kept.
    onStep("Saving voiceprints")
    if analysis.embeddingModel == voiceprintModel {
        try addVoiceprints(analysis.speakers.compactMap { s in
            guard let name = rememberedName(s.id), let embedding = s.embedding, s.seconds >= minVoiceprintSeconds else { return nil }
            return (name, embedding)
        }, call: rec.id)
    }

    try writeAtomic(rec.dir.appendingPathComponent("saved.json"), try encodeJSON(["meeting": outRel]) + "\n")
    if !config.keepAudio { Recordings.deleteAudio(rec) }
    return SavedMeeting(path: outRel, summaryError: summaryError)
}

/**
 * Writes the summary and to-dos of a meeting saved without them (the model couldn't be reached), from
 * its transcript, your notes and meeting.json. To-dos already in todo.md are kept.
 */
public func writeSummary(_ config: Config, meeting rel: String) async throws {
    let meetings = Meetings(root: config.meetingsRoot)
    let files = try meetings.read(rel)
    guard !files.transcript.trimmed.isEmpty else { throw OatcakeError("This meeting has no transcript to summarise.") }
    let notes = parseNotes(files.notes).map { Note(at: $0.stamp.map(seconds), text: $0.text) }
    let name = (rel as NSString).lastPathComponent
    let title = files.meta.title ?? name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, with: "", options: .regularExpression)
    let (summary, todo) = try await summarise(config, title: title, participants: files.meta.participants ?? [config.myName],
                                              notes: notes, transcript: files.transcript)
    try meetings.write(rel, .summary, summary)
    if !todo.isEmpty {
        // Read again: to-dos may have been added or ticked while the model was writing.
        let existing = try meetings.read(rel).todo.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
        try meetings.write(rel, .todo, existing.isEmpty ? todo : existing + "\n" + todo)
    }
}

/// The recording a meeting folder was saved from: nil when there's no meeting there, "" for a
/// meeting that names none (a Granola import, or a meeting.json that can't be read).
private func savedRecording(_ meeting: URL) -> String? {
    guard let data = try? Data(contentsOf: meeting.appendingPathComponent("meeting.json")) else { return nil }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["recording"] as? String ?? ""
}

private func mergeRuns(_ lines: [Line]) -> [Line] {
    var out: [Line] = []
    for l in lines {
        if let last = out.last, last.speaker == l.speaker, l.start - last.end < 3 {
            out[out.count - 1].text += " " + l.text
            out[out.count - 1].end = l.end
        } else {
            out.append(l)
        }
    }
    return out
}

/// "- [12:34] point", or "- point" for a prep note written before the call.
private func notesMarkdown(_ notes: [Note]) -> String {
    notes.map { n in n.at.map { "- [\(clock($0))] \(n.text)" } ?? "- \(n.text)" }.joined(separator: "\n") + "\n"
}

private let todoMarker = "=== TO-DOS ==="

/// Writes summary.md's body and todo.md's to-dos in one model call.
private func summarise(_ config: Config, title: String, participants: [String], notes: [Note], transcript: String) async throws -> (String, String) {
    // The notes stay the note-taker's own (notes.md). Here they only tell the model what mattered.
    let notesBlock = notes.isEmpty ? "" : ([
        "\(config.myName) took these notes ([mm:ss] = time into the call; \"before the call\" = prep written",
        "beforehand). They are kept separately, so don't copy them into the summary. Treat them as a signal",
        "of what mattered most to the note-taker: cover those topics fully, with the details from the",
        "transcript around each timestamp, and keep everything else brief.",
    ] + notes.map { "[\($0.at.map(clock) ?? "before the call")] \($0.text)" }).joined(separator: "\n")

    let reply = try await makeLlm(config.llm).complete(
        system: "You write concise, accurate meeting notes in Markdown. Use only facts from the transcript and notes. "
            + "Name who said or decided what. Follow the reply format exactly.",
        prompt: [
            "Meeting: \(title)",
            "Participants: \(participants.joined(separator: ", "))",
            "",
            notesBlock,
            "",
            "Reply in two parts.",
            "1. The summary: organised by topic under your own '##' headings, starting at the first '##'.",
            "   Leave action items out of it; they go in part 2. You may cite a moment as [mm:ss].",
            "2. A line reading exactly \(todoMarker), then one line per action item agreed in the call:",
            "   - [ ] What to do — Owner — due <date, only if one was stated, e.g. Fri, Oct 30> — [mm:ss]",
            "   Owner is the person's name as in the transcript; leave out any part that isn't known, and",
            "   [mm:ss] is when it was agreed. If nothing was agreed, write nothing after the marker.",
            "",
            "Transcript:",
            transcript,
        ].joined(separator: "\n"))
    let parts = reply.components(separatedBy: todoMarker)
    let todos = (parts.count > 1 ? parts[1] : "").components(separatedBy: "\n")
        .filter { $0.range(of: #"^\s*[-*]\s+\[( |x|X)\]\s+\S"#, options: .regularExpression) != nil }
        .map(\.trimmed)
    return (parts[0].trimmed + "\n", todos.isEmpty ? "" : todos.joined(separator: "\n") + "\n")
}
