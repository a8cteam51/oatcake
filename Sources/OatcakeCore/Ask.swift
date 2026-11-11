// Ask: questions about your meetings, answered by the model on this Mac. The meeting that's open is
// put in front of the model whole (its summary, to-dos, your notes and the transcript), so nearly
// every question is answered from the words that were said. The model is first asked whether the
// question reaches beyond that meeting; when it does, Oatcake searches the others for the names and
// topics the model gives and adds what it finds: their summaries, to-dos and the transcript lines
// that match. The model never opens a file or runs anything: it only sees the text it's handed.

import Foundation

/// A question already answered in this conversation.
public struct AskExchange: Sendable, Equatable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

private func askSystem(_ config: Config) -> String {
    [
        "You answer \(config.myName)'s questions about their meetings, from the meetings written out below. Each one starts with a tag like [M1].",
        "Use only what the meetings say, and name who said or decided each thing. A transcript line belongs to the person named at its start, so check who is speaking before you say that someone said or agreed to something.",
        "After each point, cite where it comes from: the meeting's tag and the [mm:ss] time of the transcript line you rely on, like [M1 12:34], or the tag alone, like [M1], for something from a summary, notes or to-dos.",
        "If the meetings below don't answer the question, say so rather than guessing. Answer in concise Markdown.",
        config.jargonLine,
    ].filter { !$0.isEmpty }.joined(separator: " ")
}

private let routeTask = """
    Don't answer the question yet. First: can it be answered from the meeting above alone, or does it reach beyond it, to earlier meetings, other meetings, or how something has gone over time?
    Reply as JSON: {"beyond": true or false, "search": [...]}. "search" is up to four short phrases to look for in the other meetings (a name, a project or a topic, one to three words each), and [] when "beyond" is false.
    """

/// The shape that comes back in. The model's server holds the reply to it.
let routeSchema = #"{"type":"object","properties":{"beyond":{"type":"boolean"},"search":{"type":"array","items":{"type":"string"}}},"required":["beyond","search"]}"#

struct AskRoute: Decodable, Equatable {
    var beyond: Bool
    var search: [String]
}

/// The most that a search of the other meetings adds, in tokens, and how many meetings it's spread over.
private let otherMeetingsTokens = 6_000
private let otherMeetingsCount = 5

/**
 * Answers a question about the meeting at `rel` (and, when the question reaches beyond it, the
 * others). `history` is what has been asked and answered so far in this conversation. The answer is
 * Markdown; where the model cited a meeting, there's a link to it (see citationLinks).
 */
public func ask(_ config: Config, meeting rel: String, question: String, history: [AskExchange] = [],
                onStep: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
    let meetings = Meetings(root: config.meetingsRoot)
    let files = try meetings.read(rel)
    let tree = meetings.tree()
    let others = tree.allMeetings.filter { $0.path != rel }
    let system = ChatMessage("system", askSystem(config))
    let think = config.llm.reasoning.ask
    // Last, after the meetings: the model keeps its reading of them for the next question.
    let tail = "\(historyBlock(history))Today is \(longDate(Date())).\nQuestion: \(question)"
    let largest = largestContext(config.llm)
    let fixed = LocalModels.tokens(in: system.content + tail + routeTask) + replyTokens + 300
    let open = openMeetingText(config, rel, files, question: question, tokens: max(1_000, largest - fixed))
    let openTokens = LocalModels.tokens(in: open)
    // Room for what a search may add is asked for now, so the model isn't started again to fit it.
    let extra = others.isEmpty ? 0 : max(0, min(otherMeetingsTokens, largest - fixed - openTokens))

    return try await withModel(config.llm, tokens: openTokens + fixed + extra) { model, _ in
        onStep("Reading this call")
        var found: [(path: String, text: String)] = []
        if extra >= 500 {
            do {
                let reply = try await model.complete([system, ChatMessage("user", "\(open)\n\n\(tail)\n\n\(routeTask)")], schema: routeSchema, think: think, maxTokens: 4_096)
                if let route = try? parseJsonObject(AskRoute.self, reply), route.beyond {
                    onStep("Looking through your other meetings")
                    found = otherMeetings(meetings, others: others, besides: rel, phrases: route.search, tokens: extra)
                }
            } catch {
                // Stopped: stop. Anything else: answer from this meeting alone.
                if isCancellation(error) { throw error }
            }
        }
        onStep("Writing the answer")
        let prompt = ([open] + found.map(\.text)).joined(separator: "\n\n") + "\n\n" + tail
        let answer = try await model.complete([system, ChatMessage("user", prompt)], think: think, maxTokens: replyTokens)
        return citationLinks(answer, sources: [rel] + found.map(\.path))
    }
}

/// Whether an error is a request that was stopped on purpose.
public func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

// MARK: - What the model is given

/// "Thu, Oct 29, 2026": a date the model can't misread.
private func longDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, MMM d, yyyy"
    return formatter.string(from: date)
}

private func heading(_ tag: Int, _ rel: String, _ meta: MeetingMeta, note: String = "") -> String {
    var lines = ["[M\(tag)] \(titleOfMeeting(rel, meta))\(parseISO(meta.startedAt).map { " · \(longDate($0))" } ?? "")\(note)"]
    if let people = meta.participants, !people.isEmpty { lines.append("Participants: \(people.joined(separator: ", "))") }
    return lines.joined(separator: "\n")
}

private func section(_ title: String, _ body: String) -> String? {
    body.trimmed.isEmpty ? nil : "\(title):\n\(body.trimmed)"
}

/// The meeting that's open: everything in it, or as much of the transcript as there's room for.
private func openMeetingText(_ config: Config, _ rel: String, _ files: MeetingFiles, question: String, tokens: Int) -> String {
    let before = [
        heading(1, rel, files.meta, note: " (the meeting \(config.myName) has open)"),
        section("Summary", forReading(files.summary)),
        section("To-dos ([x] = done)", files.todo),
        section("\(config.myName)'s own notes", files.notes),
    ].compactMap { $0 }.joined(separator: "\n\n")
    let (transcript, whole) = transcriptFor(files.transcript, question: question, tokens: max(500, tokens - LocalModels.tokens(in: before) - 50))
    let title = whole ? "Transcript ([mm:ss] is the time into the call)"
        : "Transcript ([mm:ss] is the time into the call; the call is too long to give whole, so these are the parts nearest the question)"
    return [before, section(title, transcript)].compactMap { $0 }.joined(separator: "\n\n")
}

private let commonWords: Set<String> = ["about", "anyone", "been", "call", "could", "does", "earlier", "everything", "from", "have", "meeting", "meetings",
                                        "said", "should", "that", "their", "them", "there", "they", "this", "today", "were", "what", "when", "where",
                                        "which", "will", "with", "would", "your"]

/// The words of a question that are worth looking for.
func questionWords(_ question: String) -> [String] {
    foldedForSearch(question).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 && !commonWords.contains($0) }
}

/**
 * A transcript as it's given to the model: whole when it fits in `tokens`. When it doesn't, the
 * paragraphs that share a word with the question, each with the one before and after it, in order;
 * or its start, when none do.
 */
func transcriptFor(_ transcript: String, question: String, tokens: Int) -> (text: String, whole: Bool) {
    if LocalModels.tokens(in: transcript) <= tokens { return (transcript.trimmed, true) }
    let paragraphs = transcript.components(separatedBy: "\n\n").filter { !$0.trimmed.isEmpty }
    let words = questionWords(question)
    var wanted = Set<Int>()
    for (i, paragraph) in paragraphs.enumerated() {
        let folded = foldedForSearch(paragraph)
        if words.contains(where: folded.contains) { wanted.formUnion([i - 1, i, i + 1]) }
    }
    var kept: [String] = []
    var used = 0
    for (i, paragraph) in paragraphs.enumerated() where wanted.isEmpty || wanted.contains(i) {
        used += LocalModels.tokens(in: paragraph) + 1
        if used > tokens, !kept.isEmpty { break }
        kept.append(paragraph)
    }
    return (kept.joined(separator: "\n\n"), false)
}

private func historyBlock(_ history: [AskExchange]) -> String {
    guard !history.isEmpty else { return "" }
    let recent = history.suffix(4).map { turn -> String in
        // Without the links: the meetings they pointed to may not be in front of the model now.
        let answer = turn.answer.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return "Question: \(turn.question)\nAnswer: \(answer.prefix(1_500))"
    }
    return "Earlier in this conversation:\n\(recent.joined(separator: "\n\n"))\n\n"
}

/**
 * The other meetings a question reaches for: those with one of the phrases in them (every word of
 * it, anywhere in the meeting), and the ones in the same folder as the open meeting, which is where
 * a series lives. The most phrases first, then the newest. Each is given as its summary, its to-dos
 * and the transcript lines that match, tagged [M2], [M3]… in the order returned.
 */
func otherMeetings(_ meetings: Meetings, others: [TreeNode], besides rel: String, phrases: [String], tokens: Int) -> [(path: String, text: String)] {
    let phrases = phrases.map(\.trimmed).filter { !$0.isEmpty }.prefix(4)
    let folderOf = { (path: String) in (path as NSString).deletingLastPathComponent }
    let listed = others.map { (path: $0.path, label: "\($0.title ?? $0.name) \(folderOf($0.path))") }
    var score: [String: Int] = [:]
    var matched: [String: [String]] = [:]
    for phrase in phrases {
        for hit in meetings.search(phrase, in: listed) {
            score[hit.path, default: 0] += 10
            matched[hit.path, default: []].append(phrase)
        }
    }
    let folder = folderOf(rel)
    if !folder.isEmpty {
        for node in others where folderOf(node.path) == folder { score[node.path, default: 0] += 3 }
    }
    let ranked = others.filter { score[$0.path] != nil }
        .sorted { (score[$0.path]!, $0.startedAt ?? .distantPast) > (score[$1.path]!, $1.startedAt ?? .distantPast) }
        .prefix(otherMeetingsCount)
    guard !ranked.isEmpty else { return [] }

    let each = tokens / ranked.count
    var found: [(path: String, text: String)] = []
    for node in ranked {
        guard let files = try? meetings.read(node.path) else { continue }
        let lines = files.transcript.components(separatedBy: "\n\n").filter { paragraph in
            let folded = foldedForSearch(paragraph)
            return (matched[node.path] ?? []).contains { phrase in
                foldedForSearch(phrase).split(whereSeparator: \.isWhitespace).allSatisfy { folded.contains($0) }
            }
        }.prefix(8).map { String($0.trimmed.prefix(700)) }
        let text = [
            heading(found.count + 2, node.path, files.meta),
            section("Summary", forReading(files.summary)) ?? "Summary: none was written.",
            section("To-dos ([x] = done)", files.todo),
            section("Transcript lines that match the search ([mm:ss] is the time into that call)", lines.joined(separator: "\n\n")),
        ].compactMap { $0 }.joined(separator: "\n\n")
        // Cut to its share of the room, at about three characters a token.
        found.append((node.path, String(text.prefix(each * 3))))
    }
    return found
}

// MARK: - Links in the answer

private let hrefCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

/**
 * The model cites a meeting by its tag: "[M2]", or "[M2 12:34]" for a line of its transcript. Here
 * each becomes a Markdown link the app opens: to the meeting (its target is the meeting folder's
 * path, percent-encoded), and with a time, to that moment in its transcript ("#12:34" on the end).
 * `sources` are the meetings' paths in tag order; the first is the open meeting, whose times are
 * shown as the time alone. A tag for a meeting that wasn't given is left as the model wrote it.
 */
func citationLinks(_ answer: String, sources: [String]) -> String {
    let time = try! NSRegularExpression(pattern: #"\d{1,2}:\d\d(?::\d\d)?"#)
    func href(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: hrefCharacters) ?? path }
    func label(_ path: String) -> String {
        meetingLinkText(path) ?? ((path as NSString).lastPathComponent).replacingOccurrences(of: "]", with: "\\]")
    }
    func replacing(_ text: String, _ pattern: String, _ link: ([String?]) -> String?) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let replacement = link(groups(match, in: text)), let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }
    // "[M2]", "[M2 12:34]", "[M2, 12:34, 15:02]"; not one that's already a link's text.
    var out = replacing(answer, #"\[M(\d+)([^\]\[]*)\](?!\()"#) { g in
        guard let n = g[1].flatMap({ Int($0) }), n >= 1, n <= sources.count else { return nil }
        let path = sources[n - 1]
        let rest = g[2] ?? ""
        let times = time.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).compactMap { Range($0.range, in: rest).map { String(rest[$0]) } }
        if times.isEmpty { return "[\(label(path))](\(href(path)))" }
        return times.map { "[\(n == 1 ? $0 : "\(label(path)) · \($0)")](\(href(path))#\($0))" }.joined(separator: ", ")
    }
    // With only the open meeting in front of it, a bare "[12:34]" can only be a time in that one.
    if sources.count == 1 {
        out = replacing(out, #"\[(\d{1,2}:\d\d(?::\d\d)?)\](?!\()"#) { g in g[1].map { "[\($0)](\(href(sources[0]))#\($0))" } }
    }
    return out
}
