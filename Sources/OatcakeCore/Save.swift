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

/// How close a voice match has to be for the voice to get that person's name with nobody checking.
/// Review suggests any match from 0.6 (Speakers.swift), where you see it and can say no. The same
/// person measured 0.85–0.95 there; a match in the 0.6s has been someone else in the background.
public let unattendedMatch = 0.8

/// Who's who as a meeting saved without checking gets it: a voice you named during the call, or one
/// Oatcake recognised from before and is sure of, under that person's name, and every other voice
/// unnamed ("Voice 1"…), whatever the model guessed from the conversation. A guess is a name that was
/// said on the call, so it's often someone else's; and each "Voice N" stands for one voice only, so it
/// can be given its name later wherever it's been written. A match that isn't sure enough is still
/// suggested when the voices are named.
public func suggestedDecisions(_ analysis: Analysis) -> [String: Decision] {
    Dictionary(uniqueKeysWithValues: analysis.speakers.map { s in
        let sure = s.suggestion.flatMap { $0.how == .live || ($0.how == .voice && ($0.score ?? 0) >= unattendedMatch) ? $0.name.trimmed : nil }
        return (s.id, Decision.name(sure ?? ""))
    })
}

/// Whether these decisions leave out a voice that's in the meeting as it was saved without checking.
/// Its to-dos go with it when the meeting is saved again; what the summary says of it can only go by
/// writing the summary again, which is the app's to ask for.
public func leavesOutSavedVoice(_ rec: Recording, _ decisions: [String: Decision]) -> Bool {
    guard let before = Recordings.savedInfo(rec.dir)?.names else { return false }
    return decisions.contains { $0.value == .ignore && before[$0.key] != nil }
}

/**
 * Writes the meeting folder (transcript.md, notes.md, meeting.json) into `folder` (relative to the
 * Meetings folder) and saves confirmed voiceprints. Returns the meeting's path. No model is involved:
 * the summary and to-dos are written afterwards (writeSummary), so nothing from the call waits on one.
 * `title` replaces the one the recording was started with.
 *
 * `unchecked`: saved without anyone checking who's who (Settings › General › After a call). No voices
 * are remembered, and the recording's analysis and clips are kept so they can be named later.
 * `existing`: naming them later. The meeting already saved from this recording, wherever it is now, is
 * written again in place: its transcript and meeting.json, with the new names carried into its
 * summary and to-dos. Its title and your notes stay as they are.
 */
@discardableResult
public func saveMeeting(_ config: Config, _ rec: Recording, decisions: [String: Decision], folder: String, title: String? = nil,
                        unchecked: Bool = false, into existing: String? = nil, voiceprints: URL = Paths.voiceprints) throws -> String {
    let analysis = try loadAnalysis(rec)
    let notes = Recordings.notes(in: rec.dir)
    var title = title.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? analysis.title
    // With no name set in Settings, your lines still need one to be read back as yours.
    let myName = config.myName.trimmed.isEmpty ? "Me" : config.myName.trimmed

    /// The decision a voice ends up with once merges are followed (nil for your microphone).
    func settled(_ id: String, _ seen: Set<String> = []) -> (id: String, decision: Decision?)? {
        if id == me { return nil }
        let d = decisions[id]
        if case .merge(let into) = d, !seen.contains(id) { return settled(into, seen.union([id])) }
        return (id, d)
    }
    func nameOf(_ id: String) -> String? {
        guard let s = settled(id) else { return myName }
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
    for name in [myName] + paragraphs.map(\.speaker) where name != "Several people" && !participants.contains(name) {
        participants.append(name)
    }
    let transcript = paragraphs.map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n"

    // The name each voice's lines are saved under, for naming them later.
    var savedNames: [String: String] = [:]
    for s in analysis.speakers { savedNames[s.id] = nameOf(s.id) }

    var outRel: String
    var out: URL
    // Keep the recording's choice even if a summary is written later. When reviewing voices in
    // an already saved meeting, its own choice takes precedence (including a return to Default).
    var template = rec.summaryTemplate
    if let existing {
        outRel = existing
        out = try resolveInside(config.meetingsRoot, existing)
        guard savedRecording(out, in: config.meetingsRoot) == rec.id else { throw OatcakeError("The meeting saved from this call couldn’t be found.") }
        let kept = fileInside(config.meetingsRoot, out, "meeting.json").flatMap { tryJSON(MeetingMeta.self, $0) }
        if let keptTitle = kept?.title?.trimmed, !keptTitle.isEmpty { title = keptTitle }
        template = kept?.template
    } else {
        let startedAt = parseISO(analysis.startedAt) ?? rec.startedAt
        let name = meetingFolderName(title: title, startedAt: startedAt)
        // Another call with the same title in the same minute keeps its folder, and this one is numbered.
        // Saving this recording again (after a failure) goes back into its own folder.
        outRel = folder.isEmpty ? name : folder + "/" + name
        out = try resolveInside(config.meetingsRoot, outRel)
        var number = 2
        while let other = savedRecording(out, in: config.meetingsRoot), other != rec.id {
            outRel = (folder.isEmpty ? name : folder + "/" + name) + " (\(number))"
            out = try resolveInside(config.meetingsRoot, outRel)
            number += 1
        }
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try writeAtomic(out.appendingPathComponent("transcript.md"), transcript)
    // Naming voices later leaves notes.md as it is: it may have been edited since.
    if existing == nil, !notes.isEmpty { try writeAtomic(out.appendingPathComponent("notes.md"), notesMarkdown(notes)) }
    struct Meta: Encodable {
        var title: String
        var startedAt: String
        var endedAt: String
        var participants: [String]
        var recording: String
        var template: String?
        var calendarIDs: [UUID]?
    }
    try writeAtomic(out.appendingPathComponent("meeting.json"),
                    try encodeJSON(Meta(title: title, startedAt: analysis.startedAt, endedAt: analysis.endedAt,
                                        participants: participants, recording: rec.id, template: template, calendarIDs: rec.calendarIDs)) + "\n")

    // Naming voices later: the summary and to-dos say the new names where they said the old ones.
    if existing != nil, let before = Recordings.savedInfo(rec.dir)?.names {
        // A name two voices were saved under (both recognised as one person) that they no longer
        // share can't be told apart in a sentence: it's left as it is there.
        var after: [String: Set<String>] = [:]
        for (id, old) in before {
            if let new = savedNames[id] { after[old, default: []].insert(new) }
        }
        let renames = after.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { $0.key != $0.value }
        // A voice left out now takes its to-dos with it, unless a voice that stays was saved under the
        // same name. (The summary is written again without it: see leavesOutSavedVoice.)
        let gone = Set(before.filter { savedNames[$0.key] == nil }.values).subtracting(after.keys)
        if !renames.isEmpty || !gone.isEmpty {
            let meetings = Meetings(root: config.meetingsRoot)
            let files = try meetings.read(outRel)
            for (file, text) in [(MeetingFile.summary, files.summary), (.todo, files.todo), (.draft, files.draft)] where !text.isEmpty {
                let renamed = renamePeople(file == .todo ? withoutTodos(of: gone, in: text) : text, renames)
                if renamed != text { try meetings.write(outRel, file, renamed) }
            }
        }
    }

    // Only now the meeting is written, so a save that's retried doesn't add the same voices twice.
    // Fingerprints from another model (an analysis made by the Electron version) aren't kept, and
    // neither are names nobody has checked.
    if !unchecked, analysis.embeddingModel == voiceprintModel {
        // Voices merged into one person in review give one fingerprint for the call: the one with the
        // most speech, not a stray half-minute of them.
        var kept = Set<String>()
        try addVoiceprints(analysis.speakers.sorted { $0.seconds > $1.seconds }.compactMap { s in
            guard let name = rememberedName(s.id), let embedding = s.embedding, s.seconds >= minVoiceprintSeconds, kept.insert(name).inserted else { return nil }
            return (name, embedding)
        }, call: rec.id, file: voiceprints)
    }

    let info = unchecked ? SavedInfo(meeting: outRel, unchecked: true, names: savedNames) : SavedInfo(meeting: outRel)
    try writeAtomic(rec.dir.appendingPathComponent("saved.json"), try encodeJSON(info) + "\n")
    // An unchecked meeting keeps its clips, to play when its voices are named.
    if !config.keepAudio { unchecked ? Recordings.deleteTracks(rec.dir) : Recordings.deleteAudio(rec) }
    return outRel
}

/**
 * Puts new names in place of old ones in a summary or to-dos, as whole words only ("Voice 1" isn't
 * the start of "Voice 12"). Done in two passes, so names that swap places don't run into each other.
 * "Several people" is left alone: it may be any of several voices.
 */
func renamePeople(_ text: String, _ renames: [String: String]) -> String {
    let pairs = renames.filter { !$0.key.trimmed.isEmpty && $0.key != $0.value && $0.key != "Several people" && $0.value != "Several people" }
        .sorted { $0.key.count > $1.key.count }
    var out = text
    var placed: [(token: String, name: String)] = []
    for (i, pair) in pairs.enumerated() {
        let token = "\u{E000}\(i)\u{E001}"
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: pair.key) + #"(?![\p{L}\p{N}_])"#
        out = out.replacingOccurrences(of: pattern, with: token, options: .regularExpression)
        placed.append((token, pair.value))
    }
    for p in placed { out = out.replacingOccurrences(of: p.token, with: p.name) }
    return out
}

/// To-dos without the ones these people own. Every other line stays as it is, ticks included.
func withoutTodos(of owners: Set<String>, in markdown: String) -> String {
    let theirs = Set(parseTodos(markdown).filter { owners.contains($0.owner) }.map(\.line))
    guard !theirs.isEmpty else { return markdown }
    return markdown.components(separatedBy: "\n").enumerated().filter { !theirs.contains($0.offset) }.map(\.element).joined(separator: "\n")
}

/// The recording a meeting folder was saved from: nil when there's no meeting there, "" for a
/// meeting that names none (a Granola import, or a meeting.json that can't be read).
private func savedRecording(_ meeting: URL, in root: URL) -> String? {
    guard let data = fileInside(root, meeting, "meeting.json").flatMap({ try? Data(contentsOf: $0) }) else { return nil }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["recording"] as? String ?? ""
}

/// A summary and its to-dos, as the model wrote them.
public struct SummaryDraft: Sendable, Equatable {
    public var summary: String
    public var todo: String
    /// Why there are no to-dos, when it's because the model's reply couldn't be read rather than
    /// because nothing was agreed. nil otherwise.
    public var todoProblem: String?
    public init(summary: String, todo: String, todoProblem: String? = nil) {
        self.summary = summary
        self.todo = todo
        self.todoProblem = todoProblem
    }
}

/// What a draft says when the model's reply for the to-dos wasn't the JSON it was asked for.
public let todosUnreadMessage = "The model’s reply for the to-dos wasn’t in the form Oatcake asks for, so none were collected from this call."

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
    // Anything typed into the summary while the model was writing stays, with the model's below it.
    try meetings.update(rel, .summary) { now in
        let typed = now.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
        return typed.trimmed.isEmpty ? draft.summary : typed + "\n\n" + draft.summary
    }
    if !draft.todo.isEmpty {
        // As the file is now: to-dos may have been added or ticked while the model was writing, or be
        // being ticked as these arrive.
        try meetings.update(rel, .todo) { now in
            let existing = now.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
            return existing.isEmpty ? draft.todo : existing + "\n" + draft.todo
        }
    }
}

/// What Regenerate writes again: a meeting's summary, or its to-dos.
public enum SummaryPart: Sendable { case summary, todos }

/// Which instructions a summary is written with.
public enum SummaryTemplateChoice: Hashable, Sendable {
    /// The meeting's own: the template it was last regenerated with, or the summary instructions.
    case meetings
    /// Picked for Regenerate summary: a template, by name, or nil for the summary instructions.
    case picked(String?)
}

/// Regenerate: puts a new draft of one part in place of the old one. `previous` is that part as it was
/// when the model was asked. If it has changed since (edited somewhere else), nothing is written. A
/// summary written with a template picked for it keeps that template for the meeting from then on.
public func writeRegenerated(_ part: SummaryPart, _ draft: SummaryDraft, config: Config, meeting rel: String, previous: String,
                             template: SummaryTemplateChoice = .meetings) throws {
    let meetings = Meetings(root: config.meetingsRoot)
    let now = try meetings.read(rel)
    switch part {
    case .summary:
        guard now.summary == previous else { throw OatcakeError("The summary was changed while it was being regenerated.") }
        guard !draft.summary.trimmed.isEmpty else { throw OatcakeError("The model returned an empty summary.") }
        try meetings.write(rel, .summary, draft.summary)
        // The summary is written by now: a meeting.json that can't be read only means the choice isn't kept.
        if case .picked(let name) = template { try? meetings.setSummaryTemplate(rel, config.summaryTemplate(named: name)?.name) }
    case .todos:
        guard now.todo == previous else { throw OatcakeError("The to-dos were changed while they were being regenerated.") }
        if let problem = draft.todoProblem { throw OatcakeError(problem) }
        try meetings.write(rel, .todo, draft.todo)
    }
}

/// Asks the model for a meeting's summary and to-dos, or for just one of them. Nothing is written.
public func draftSummary(_ config: Config, meeting rel: String, only part: SummaryPart? = nil,
                         template: SummaryTemplateChoice = .meetings) async throws -> SummaryDraft {
    let meetings = Meetings(root: config.meetingsRoot)
    let files = try meetings.read(rel)
    guard !files.transcript.trimmed.isEmpty else { throw OatcakeError("This meeting has no transcript to summarise.") }
    let notes = parseNotes(files.notes).map { Note(at: $0.stamp.map(seconds), text: $0.text) }
    let name: String? = switch template {
    case .meetings: files.meta.template
    case .picked(let name): name
    }
    // With to-dos turned off (Settings › General), only the summary is asked for, so todo.md is left alone.
    let part = part ?? (config.todosEnabled ? nil : .summary)
    return try await summarise(config, title: titleOfMeeting(rel, files.meta), participants: files.meta.participants ?? [config.myName],
                               notes: notes, transcript: files.transcript, only: part, summaryTask: config.summaryTask(template: name))
}

/// A paragraph of the transcript runs for about this long at most before the next pause starts a new one.
private let longestParagraph = 30.0

/**
 * Consecutive lines from one speaker read as one paragraph. A long turn breaks at a pause about every
 * half minute, so each part has its own time to jump to (lines arrive split at pauses already).
 */
func mergeRuns(_ lines: [Line]) -> [Line] {
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

/// Room for one request's reasoning and reply with the model that's set: its own, or replyTokens for
/// a server of your own.
func replyRoom(_ llm: LlmConfig) -> Int { LocalModels.find(llm.model)?.replyTokens ?? replyTokens }

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

/// What the model is told counts as a to-do. It can be changed in Settings › Summaries too. Measured
/// against other wordings on made-up calls and real ones: this one left out the most that wasn't
/// agreed without losing what a task was about (a stricter one that also ruled out decisions did).
public let defaultTodoInstructions = """
    List the action items people agreed to in this meeting: the things someone said they will do after the call. One item for each piece of work.
    - Leave out what was only talked about or suggested, and anything a person was asked to do and didn't take on.
    - Leave out what was done during the call itself, and small talk or personal plans.
    - If you're not sure someone took a thing on, leave it out.
    """

/// The shape of a to-do, which the app reads back: not for changing in Settings.
let todosFormat = """
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
private func summarise(_ config: Config, title: String, participants: [String], notes: [Note], transcript: String, only: SummaryPart?,
                       summaryTask: String) async throws -> SummaryDraft {
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
    let todosTask = config.todosTask
    let reasoning = config.llm.reasoning
    let room = replyRoom(config.llm)
    let overhead = LocalModels.tokens(in: head + summaryTask + todosTask) + room + 200
    let parts = splitTranscript(transcript, tokens: max(2_000, largestContext(config.llm) - overhead))

    var summaries: [String] = []
    var todos: [String] = []
    var todosUnread = false
    for (i, part) in parts.enumerated() {
        let which = parts.count > 1 ? ", part \(i + 1) of \(parts.count)" : ""
        let prompt = "\(head)\n\nTranscript ([mm:ss] is the time into the call)\(which):\n\(part)\n\n"
        let (summary, items) = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + overhead) { model, _ in
            // Regenerate asks only for the part being written again.
            var summary = "", items: [String]? = []
            if only != .todos {
                summary = summaryBody(try await model.complete([system, ChatMessage("user", prompt + summaryTask)], think: reasoning.summary, maxTokens: room))
            }
            if only != .summary {
                items = todoLines(try await model.complete([system, ChatMessage("user", prompt + todosTask)], schema: todosSchema, think: reasoning.todos, maxTokens: room))
            }
            return (summary, items)
        }
        summaries.append(summary)
        todos += items ?? []
        if items == nil { todosUnread = true }
    }
    var summary = summaries.first ?? ""
    if summaries.count > 1, only != .todos {
        let joined = summaries.enumerated().map { "Notes on part \($0 + 1) of \(summaries.count):\n\($1)" }.joined(separator: "\n\n")
        let prompt = "\(head)\n\nThe meeting was long, so notes were written on each part of it in turn. Here they are, in order.\n\n\(joined)\n\n\(mergeTask)\n\(summaryTask)"
        summary = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + room) { model, _ in
            summaryBody(try await model.complete([system, ChatMessage("user", prompt)], think: reasoning.summary, maxTokens: room))
        }
    }
    // Everyone is they/them: a he or she from the model is a guess from a name (theyThem).
    summary = theyThem(summary, names: participants)
    let neutral = todos.isEmpty ? [] : theyThem(todos.joined(separator: "\n"), names: participants).components(separatedBy: "\n")
    var seen = Set<String>()
    let unique = neutral.filter { seen.insert($0.lowercased()).inserted }
    return SummaryDraft(summary: summary.trimmed + "\n", todo: unique.isEmpty ? "" : unique.joined(separator: "\n") + "\n",
                        todoProblem: todosUnread ? todosUnreadMessage : nil)
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
/// parts it didn't know left out. nil when the reply isn't that JSON at all (a server of your own
/// that doesn't hold the model to a shape, or a reply cut short), which isn't the same as no to-dos.
func todoLines(_ reply: String) -> [String]? {
    struct Reply: Decodable {
        struct Item: Decodable {
            var task: String?
            var owner: String?
            var due: String?
            var at: String?
        }
        var todos: [Item]
    }
    guard let parsed = try? parseJsonObject(Reply.self, reply) else { return nil }
    /// A small model sometimes writes the word instead of leaving the value empty.
    func known(_ value: String?) -> String? {
        guard let v = value?.trimmed, !v.isEmpty, !wordsForNothing.contains(v.lowercased()) else { return nil }
        return v.replacingOccurrences(of: " — ", with: ", ")
    }
    return parsed.todos.compactMap { item in
        guard let task = known(item.task) else { return nil }
        var line = "- [ ] \(task.prefix(1).uppercased() + task.dropFirst())"
        if let owner = known(item.owner) { line += " — \(owner)" }
        if let due = known(item.due) { line += " — due \(due)" }
        if let at = known(item.at)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), at.range(of: "^\(stampForm)$", options: .regularExpression) != nil {
            line += " — [\(at)]"
        }
        return line
    }
}
