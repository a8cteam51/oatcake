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

/**
 * Writes the meeting folder (transcript.md, notes.md, meeting.json) into `folder` (relative to the
 * Meetings folder) and saves confirmed voiceprints. Returns the meeting's path. No model is involved:
 * the summary and to-dos are written afterwards (writeSummary), so nothing from the call waits on one.
 * `title` replaces the one the recording was started with.
 */
@discardableResult
public func saveMeeting(_ config: Config, _ rec: Recording, decisions: [String: Decision], folder: String, title: String? = nil) throws -> String {
    let analysis = try loadAnalysis(rec)
    let notes = Recordings.loadNotes(rec.id)
    let title = title.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? analysis.title

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

    let startedAt = parseISO(analysis.startedAt) ?? rec.startedAt
    let name = meetingFolderName(title: title, startedAt: startedAt)
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
    if !notes.isEmpty { try notesMarkdown(notes).write(to: out.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
    struct Meta: Encodable {
        var title: String
        var startedAt: String
        var endedAt: String
        var participants: [String]
        var recording: String
    }
    try (try encodeJSON(Meta(title: title, startedAt: analysis.startedAt, endedAt: analysis.endedAt,
                             participants: participants, recording: rec.id)) + "\n")
        .write(to: out.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

    // Only now the meeting is written, so a save that's retried doesn't add the same voices twice.
    // Fingerprints from another model (an analysis made by the Electron version) aren't kept.
    if analysis.embeddingModel == voiceprintModel {
        try addVoiceprints(analysis.speakers.compactMap { s in
            guard let name = rememberedName(s.id), let embedding = s.embedding, s.seconds >= minVoiceprintSeconds else { return nil }
            return (name, embedding)
        }, call: rec.id)
    }

    try writeAtomic(rec.dir.appendingPathComponent("saved.json"), try encodeJSON(["meeting": outRel]) + "\n")
    if !config.keepAudio { Recordings.deleteAudio(rec) }
    return outRel
}

/// The recording a meeting folder was saved from: nil when there's no meeting there, "" for a
/// meeting that names none (a Granola import, or a meeting.json that can't be read).
private func savedRecording(_ meeting: URL) -> String? {
    guard let data = try? Data(contentsOf: meeting.appendingPathComponent("meeting.json")) else { return nil }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["recording"] as? String ?? ""
}

/// A summary and its to-dos, as the model wrote them.
public struct SummaryDraft: Sendable, Equatable {
    public var summary: String
    public var todo: String
    public init(summary: String, todo: String) {
        self.summary = summary
        self.todo = todo
    }
}

/**
 * Writes a saved meeting's summary and to-dos from its transcript, your notes and meeting.json. It
 * runs after every save, and again from Write summary when the model couldn't be reached.
 */
public func writeSummary(_ config: Config, meeting rel: String) async throws {
    try writeSummary(try await draftSummary(config, meeting: rel), config: config, meeting: rel)
}

/// Puts a summary and its to-dos into a meeting. To-dos already in todo.md are kept. The meeting is
/// named here rather than when the model was asked, because it can be renamed or moved meanwhile.
public func writeSummary(_ draft: SummaryDraft, config: Config, meeting rel: String) throws {
    let meetings = Meetings(root: config.meetingsRoot)
    try meetings.write(rel, .summary, draft.summary)
    if !draft.todo.isEmpty {
        // Read now: to-dos may have been added or ticked while the model was writing.
        let existing = try meetings.read(rel).todo.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
        try meetings.write(rel, .todo, existing.isEmpty ? draft.todo : existing + "\n" + draft.todo)
    }
}

/// Asks the model for a meeting's summary and to-dos. Nothing is written.
public func draftSummary(_ config: Config, meeting rel: String) async throws -> SummaryDraft {
    let meetings = Meetings(root: config.meetingsRoot)
    let files = try meetings.read(rel)
    guard !files.transcript.trimmed.isEmpty else { throw OatcakeError("This meeting has no transcript to summarise.") }
    let notes = parseNotes(files.notes).map { Note(at: $0.stamp.map(seconds), text: $0.text) }
    let (summary, todo) = try await summarise(config, title: titleOfMeeting(rel, files.meta), participants: files.meta.participants ?? [config.myName],
                                              notes: notes, transcript: files.transcript)
    return SummaryDraft(summary: summary, todo: todo)
}

/// A paragraph of the transcript runs for about this long at most before the next pause starts a new one.
private let longestParagraph = 30.0

/**
 * Consecutive lines from one speaker read as one paragraph. A long turn breaks at a pause about every
 * half minute, so each part has its own time to jump to (lines arrive split at pauses already).
 */
private func mergeRuns(_ lines: [Line]) -> [Line] {
    var out: [Line] = []
    for l in lines {
        if let last = out.last, last.speaker == l.speaker, l.start - last.end < 3, l.end - last.start <= longestParagraph {
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

/// Room kept for the model's reasoning and its reply.
let replyTokens = 8_192

private let notesSystem = "You write meeting notes from a call's transcript. Use only what the transcript and the note-taker's own notes say. Name who said or decided what."

/// What the model is told when it writes a summary, after it has been given the transcript. It can
/// be changed in Settings › Summaries, which is why it says everything about the summary's shape.
public let defaultSummaryInstructions = """
    Write the summary of this meeting in Markdown.
    - Cover every topic that was discussed, each under its own '## ' heading, in the order it came up.
    - Under each heading, two to five short bullet points: what was said, decided or left open, and by whom. Decisions, numbers and dates matter most.
    - Do not list action items; they are collected separately.
    - Start your reply with the first '## ' heading and write nothing before or after the summary.
    """

private let todosTask = """
    List the action items people agreed to in this meeting: things someone said they will do. One item per commitment; leave out things that were only talked about.
    For each: task (what to do, starting with a verb, with enough detail to make sense on its own), owner (the person's name as written in the transcript), due (the date or day as it was said in the call, or null if none was said), at (the [mm:ss] time of the line where it was agreed).
    Reply as JSON: {"todos": [{"task": ..., "owner": ..., "due": ..., "at": ...}]}. If nothing was agreed, reply {"todos": []}.
    """

/// For a call done in parts: said before the summary's own instructions.
private let mergeTask = """
    Join these notes into one summary of the whole meeting. A topic that was returned to later is written up once, and every decision, number and date is kept, with who it belongs to.
    """

/// The shape the to-dos come back in. The model's server holds the reply to it.
let todosSchema = #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"owner":{"type":["string","null"]},"due":{"type":["string","null"]},"at":{"type":["string","null"]}},"required":["task","owner","due","at"]}}},"required":["todos"]}"#

/**
 * Writes summary.md's body and todo.md's to-dos. The summary and the to-dos are asked for one after
 * the other, each a plain task with the transcript in front of it: a small model follows that far
 * better than one long set of instructions, and the second question costs little because the model
 * has just read the same transcript. A call too long for the model to take in at once on this Mac
 * is done in parts, and the parts' notes are joined.
 */
private func summarise(_ config: Config, title: String, participants: [String], notes: [Note], transcript: String) async throws -> (String, String) {
    // The notes stay the note-taker's own (notes.md). Here they only tell the model what mattered.
    let notesBlock = notes.isEmpty ? "" : ([
        "\(config.myName) took these notes ([mm:ss] = time into the call; \"before the call\" = prep written",
        "beforehand). They are kept separately, so don't copy them into the summary. Treat them as a signal",
        "of what mattered most to the note-taker: cover those topics fully, with the details from the",
        "transcript around each timestamp.",
    ] + notes.map { "[\($0.at.map(clock) ?? "before the call")] \($0.text)" }).joined(separator: "\n")
    let head = ["Meeting: \(title)", "Participants: \(participants.joined(separator: ", "))", config.jargonLine, notesBlock]
        .filter { !$0.isEmpty }.joined(separator: "\n")
    let system = ChatMessage("system", notesSystem)
    let summaryTask = config.summaryTask
    let reasoning = config.llm.reasoning
    let overhead = LocalModels.tokens(in: head + summaryTask + todosTask) + replyTokens + 200
    let parts = splitTranscript(transcript, tokens: max(2_000, largestContext(config.llm) - overhead))

    var summaries: [String] = []
    var todos: [String] = []
    for (i, part) in parts.enumerated() {
        let which = parts.count > 1 ? ", part \(i + 1) of \(parts.count)" : ""
        let prompt = "\(head)\n\nTranscript ([mm:ss] is the time into the call)\(which):\n\(part)\n\n"
        let (summary, items) = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + overhead) { model, _ in
            (summaryBody(try await model.complete([system, ChatMessage("user", prompt + summaryTask)], think: reasoning.summary, maxTokens: replyTokens)),
             todoLines(try await model.complete([system, ChatMessage("user", prompt + todosTask)], schema: todosSchema, think: reasoning.todos, maxTokens: replyTokens)))
        }
        summaries.append(summary)
        todos += items
    }
    var summary = summaries.first ?? ""
    if summaries.count > 1 {
        let joined = summaries.enumerated().map { "Notes on part \($0 + 1) of \(summaries.count):\n\($1)" }.joined(separator: "\n\n")
        let prompt = "\(head)\n\nThe meeting was long, so notes were written on each part of it in turn. Here they are, in order.\n\n\(joined)\n\n\(mergeTask)\n\(summaryTask)"
        summary = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + replyTokens) { model, _ in
            summaryBody(try await model.complete([system, ChatMessage("user", prompt)], think: reasoning.summary, maxTokens: replyTokens))
        }
    }
    var seen = Set<String>()
    let unique = todos.filter { seen.insert($0.lowercased()).inserted }
    return (summary.trimmed + "\n", unique.isEmpty ? "" : unique.joined(separator: "\n") + "\n")
}

/// A transcript in pieces of at most `tokens` tokens each, cut between speakers' turns. One piece
/// when it's short enough, as nearly every call is.
func splitTranscript(_ transcript: String, tokens: Int) -> [String] {
    var parts: [String] = []
    var current: [String] = []
    var size = 0
    for paragraph in transcript.components(separatedBy: "\n\n") where !paragraph.trimmed.isEmpty {
        let cost = LocalModels.tokens(in: paragraph) + 1
        if size + cost > tokens, !current.isEmpty {
            parts.append(current.joined(separator: "\n\n"))
            current = []
            size = 0
        }
        current.append(paragraph)
        size += cost
    }
    if !current.isEmpty { parts.append(current.joined(separator: "\n\n")) }
    return parts.isEmpty ? [transcript] : parts
}

/// The summary without anything the model put before its first heading, or a code fence around it.
func summaryBody(_ reply: String) -> String {
    var text = reply.trimmed
    if text.hasPrefix("```") { text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\n|\n```\s*$"#, with: "", options: .regularExpression) }
    if let heading = text.range(of: #"(?m)^## "#, options: .regularExpression) { text = String(text[heading.lowerBound...]) }
    return text.trimmed
}

/// todo.md lines from the model's JSON: "- [ ] Task — Owner — due Fri, Oct 30 — [12:34]", with the
/// parts it didn't know left out.
func todoLines(_ reply: String) -> [String] {
    struct Reply: Decodable {
        struct Item: Decodable {
            var task: String?
            var owner: String?
            var due: String?
            var at: String?
        }
        var todos: [Item]
    }
    guard let parsed = try? parseJsonObject(Reply.self, reply) else { return [] }
    /// A small model sometimes writes the word instead of leaving the value empty.
    func known(_ value: String?) -> String? {
        guard let v = value?.trimmed, !v.isEmpty, !["null", "none", "n/a", "unknown", "not stated", "not specified", "tbd"].contains(v.lowercased()) else { return nil }
        return v.replacingOccurrences(of: " — ", with: ", ")
    }
    return parsed.todos.compactMap { item in
        guard let task = known(item.task) else { return nil }
        var line = "- [ ] \(task.prefix(1).uppercased() + task.dropFirst())"
        if let owner = known(item.owner) { line += " — \(owner)" }
        if let due = known(item.due) { line += " — due \(due)" }
        if let at = known(item.at)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), at.range(of: #"^\d{1,2}:\d\d(:\d\d)?$"#, options: .regularExpression) != nil {
            line += " — [\(at)]"
        }
        return line
    }
}
