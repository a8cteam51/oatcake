// Draft for Sharing: a meeting's summary and to-dos written again for other people to read, from
// your instructions for that (Settings › Summaries) and anything asked for this draft alone. The
// model is given the summary and to-dos as they are now, edits included, and nothing else: not the
// transcript, and not your notes, so a draft can't bring back what you left out of the summary.
// It's kept in the meeting's draft.md, which only meetings it has been written for have.

import Foundation

/// What the model is told when it writes a draft for sharing. It can be changed in Settings › Summaries.
public let defaultSharingInstructions = """
    Rewrite these meeting notes as an update for people who weren't in the meeting, in Markdown.
    - Start with what was decided and what happens next, then the rest of what was discussed.
    - Keep every decision, number, date and owner as the notes give them, and add nothing they don't say.
    - Keep it short: short bullet points under a few '## ' headings.
    - Write nothing before or after the update.
    """

private let sharingSystem = "You rewrite meeting notes for sharing with other people. Use only what the notes say."

/// What the model is asked, from the meeting's summary and to-dos. `request` is what was asked for this draft alone.
func sharingPrompt(_ config: Config, title: String, participants: [String], summary: String, todo: String, request: String) -> String {
    // The to-dos as people read them: their times in the call mean nothing to anyone else.
    let todos = config.todosEnabled ? parseTodos(todo).map { t in
        "- " + ([t.text, t.owner.isEmpty ? nil : t.owner, t.due.isEmpty ? nil : "due \(t.due)", t.done ? "done" : nil]
            .compactMap { $0 }.joined(separator: " — "))
    } : []
    let head = ["Meeting: \(title)", "Participants: \(participants.joined(separator: ", "))", config.jargonLine]
        .filter { !$0.isEmpty }.joined(separator: "\n")
    var prompt = "\(head)\n\nSummary:\n\(summary.trimmed)\n"
    if !todos.isEmpty { prompt += "\nTo-dos:\n\(todos.joined(separator: "\n"))\n" }
    prompt += "\n\(config.sharingTask)"
    if !request.trimmed.isEmpty { prompt += "\n\nFor this draft only: \(request.trimmed)" }
    return prompt
}

/// Asks the model for a meeting's draft for sharing. Nothing is written.
public func draftForSharing(_ config: Config, meeting rel: String, request: String = "") async throws -> String {
    let files = try Meetings(root: config.meetingsRoot).read(rel)
    let summary = forReading(files.summary)
    guard !summary.trimmed.isEmpty else { throw OatcakeError("This meeting has no summary to draft from.") }
    let prompt = sharingPrompt(config, title: titleOfMeeting(rel, files.meta), participants: files.meta.participants ?? [config.myName],
                               summary: summary, todo: files.todo, request: request)
    let room = replyRoom(config.llm)
    let reply = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + room + 200) { model, _ in
        try await model.complete([ChatMessage("system", sharingSystem), ChatMessage("user", prompt)],
                                 think: config.llm.reasoning.sharing, maxTokens: room)
    }
    let draft = theyThem(sharingBody(reply), names: files.meta.participants ?? [])
    guard !draft.isEmpty else { throw OatcakeError("The model returned an empty draft.") }
    return draft + "\n"
}

/// Puts a new draft for sharing in the meeting. `previous` is draft.md as it was when the model was
/// asked: if it has been edited since, nothing is written.
public func writeDraftForSharing(_ draft: String, config: Config, meeting rel: String, previous: String) throws {
    let meetings = Meetings(root: config.meetingsRoot)
    guard try meetings.read(rel).draft == previous else {
        throw OatcakeError("The draft for sharing was changed while a new one was being written.")
    }
    try meetings.write(rel, .draft, draft)
}

/// The draft without a code fence around it.
func sharingBody(_ reply: String) -> String {
    var text = reply.trimmed
    if text.hasPrefix("```") { text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\n|\n```\s*$"#, with: "", options: .regularExpression) }
    return text.trimmed
}
