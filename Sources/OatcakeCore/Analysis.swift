// Turns a recording into analysis.json: transcribed lines from both tracks, the call audio split
// into speakers A, B, C…, voice matches, and short clips per speaker for review. The app runs this
// in a helper process (Oatcake --analyse <dir>), so a crash or the speech models' memory never
// touches the window or a recording in progress. Names for the voices nobody recognised are then
// suggested from the conversation by the language model (suggestNames), which the app itself runs.

import Foundation

public let me = "me"

public struct Line: Codable, Equatable, Sendable {
    /// `me`, or a speaker letter for the call audio.
    public var speaker: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    public var text: String
}

public struct Quote: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// A WAV file in the recording's clips folder.
    public var clip: String
}

public struct Suggestion: Codable, Equatable, Sendable {
    public enum How: String, Codable, Sendable { case voice, transcript }
    public var name: String
    public var how: How
    public var detail: String
}

public struct SpeakerInfo: Codable, Equatable, Sendable {
    public var id: String
    public var seconds: Double
    public var embedding: [Float]?
    public var suggestion: Suggestion?
    public var quotes: [Quote]
}

public struct Analysis: Codable, Sendable {
    public struct Me: Codable, Sendable {
        public var seconds: Double
        public var quotes: [Quote]
    }
    public var title: String
    public var startedAt: String
    public var endedAt: String
    public var lines: [Line]
    public var speakers: [SpeakerInfo]
    public var echoLinesRemoved: Int
    /// Your microphone: talking time and a few clips.
    public var me: Me?
    /// Steps that were skipped, shown on the review screen.
    public var warnings: [String]
    /// The model the embeddings came from. Missing from analyses made by the Electron version, whose
    /// fingerprints can't be saved as voiceprints any more.
    public var embeddingModel: String?
}

/// One progress message from the analysis helper (a JSON line on its standard output).
public struct AnalysisProgress: Codable, Equatable, Sendable {
    public var step: String?
    public var fraction: Double?
    public var done: Bool?
    public var error: String?
    public init(step: String? = nil, fraction: Double? = nil, done: Bool? = nil, error: String? = nil) {
        self.step = step
        self.fraction = fraction
        self.done = done
        self.error = error
    }
}

/// The five steps shown as "step N of 5"; downloads and model loading count as step 1. The helper
/// does the first four; the app does the fifth once the helper has finished.
public let analysisSteps = [
    "Transcribing your microphone",
    "Transcribing the call audio",
    "Telling voices apart",
    "Matching voices",
    "Suggesting names from the conversation",
]

public func analyse(_ dir: URL, report: @escaping (AnalysisProgress) -> Void) async throws {
    let config = Config.load()
    let call = try readJSON(CallInfo.self, dir.appendingPathComponent("call.json"))
    let meta = try readJSON(RecorderMeta.self, dir.appendingPathComponent("meta.json"))

    report(.init(step: SpeechModels.needsDownload(config.asrModel) ? "Downloading speech models (about 500 MB, first run only)" : "Loading speech models"))
    let transcriber = try await SpeechModels.loadTranscriber(config.asrModel)
    let diarizer = try await SpeechModels.loadDiarizer()

    report(.init(step: analysisSteps[0], fraction: 0))
    let mic = readPcm(dir.appendingPathComponent("mic.pcm"))
    let micLines = try await transcriber.transcribe(mic) { report(.init(step: analysisSteps[0], fraction: $0)) }
        .map { Line(speaker: me, start: $0.start + meta.micOffset, end: $0.end + meta.micOffset, text: $0.text) }

    report(.init(step: analysisSteps[1], fraction: 0))
    let system = readPcm(dir.appendingPathComponent("system.pcm"))
    let systemUtterances = try await transcriber.transcribe(system) { report(.init(step: analysisSteps[1], fraction: $0)) }

    report(.init(step: analysisSteps[2]))
    let (turns, prints) = systemUtterances.isEmpty ? ([], [:]) : try await diarize(system, diarizer: diarizer)
    let letters = speakerLetters(turns)
    let systemLines = systemUtterances
        .flatMap { splitBySpeaker($0, turns: turns, letters: letters) }
        .map { Line(speaker: $0.speaker, start: $0.start + meta.systemOffset, end: $0.end + meta.systemOffset, text: $0.text) }

    // On speakers, the mic also hears the other side. Drop mic lines that repeat call audio.
    let keptMic = micLines.filter { !isEcho($0, systemLines) }
    let lines = (keptMic + systemLines).sorted { $0.start < $1.start }

    report(.init(step: analysisSteps[3]))
    let clips = dir.appendingPathComponent("clips", isDirectory: true)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    let voiceprints = Voiceprints.load()
    let byLetter = Dictionary(letters.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
    // From the lines rather than the turns: when diarisation finds nothing, the call audio is all
    // speaker "A", and it still needs a card in review (or its lines would be dropped on save).
    var seen = Set<String>()
    let speakers: [SpeakerInfo] = try systemLines.map(\.speaker).filter { seen.insert($0).inserted }.map { id in
        let own = turns.filter { letters[$0.speaker] == id }
        let embedding = byLetter[id].flatMap { prints[$0] }
        let voice = embedding.flatMap { voiceprints.match($0) }
        let quotes = try clipsFor(systemLines.filter { $0.speaker == id }, prefix: id, audio: system, offset: meta.systemOffset, into: clips)
        let seconds = own.isEmpty
            ? systemLines.filter { $0.speaker == id }.reduce(0) { $0 + $1.end - $1.start }
            : own.reduce(0) { $0 + $1.end - $1.start }
        return SpeakerInfo(id: id, seconds: seconds, embedding: embedding,
                           suggestion: voice.map { Suggestion(name: $0.name, how: .voice, detail: String(format: "voice match %.2f", $0.score)) },
                           quotes: quotes)
    }

    // A few clips of your own voice, for review.
    let meInfo = Analysis.Me(seconds: keptMic.reduce(0) { $0 + $1.end - $1.start },
                             quotes: try clipsFor(keptMic, prefix: "me", audio: mic, offset: meta.micOffset, into: clips))

    let analysis = Analysis(title: call.title, startedAt: meta.startedAt, endedAt: meta.endedAt, lines: lines,
                            speakers: speakers.sorted { $0.seconds > $1.seconds },
                            echoLinesRemoved: micLines.count - keptMic.count, me: meInfo, warnings: [],
                            embeddingModel: voiceprintModel)
    try writeAtomic(dir.appendingPathComponent("analysis.json"), try encodeJSON(analysis))
}

/// The three longest lines of at least 1.5 s, in time order, each with a clip of up to 10 s.
private func clipsFor(_ lines: [Line], prefix: String, audio: [Float], offset: Double, into dir: URL) throws -> [Quote] {
    let chosen = lines.filter { $0.end - $0.start >= 1.5 }.sorted { $0.text.count > $1.text.count }.prefix(3).sorted { $0.start < $1.start }
    return try chosen.enumerated().map { i, line in
        let clip = dir.appendingPathComponent("\(prefix)-\(i + 1).wav")
        let from = line.start - offset
        try writeWav(clip, slice(audio, from, min(from + 10, line.end - offset)))
        return Quote(text: line.text, start: line.start, end: line.end, clip: clip.path)
    }
}

/// Letters by order of first appearance: A speaks first.
func speakerLetters(_ turns: [Turn]) -> [String: String] {
    var letters: [String: String] = [:]
    for turn in turns.sorted(by: { $0.start < $1.start }) where letters[turn.speaker] == nil {
        letters[turn.speaker] = String(UnicodeScalar(UInt8(65 + letters.count % 26)))
    }
    return letters
}

/// Gives each word the speaker whose turn covers (or is nearest) its midpoint, then groups runs.
func splitBySpeaker(_ u: Utterance, turns: [Turn], letters: [String: String]) -> [Line] {
    guard !turns.isEmpty else { return [Line(speaker: "A", start: u.start, end: u.end, text: u.text)] }
    func speakerAt(_ w: Word) -> String {
        let mid = (w.start + w.end) / 2
        var best = turns[0]
        var bestGap = Double.infinity
        for t in turns {
            let gap = mid < t.start ? t.start - mid : mid > t.end ? mid - t.end : 0
            if gap < bestGap { (best, bestGap) = (t, gap) }
        }
        return letters[best.speaker] ?? "A"
    }
    let words = u.words.isEmpty ? [Word(text: u.text, start: u.start, end: u.end)] : u.words
    var lines: [Line] = []
    for w in words {
        let speaker = speakerAt(w)
        if let last = lines.last, last.speaker == speaker {
            lines[lines.count - 1].text += " " + w.text
            lines[lines.count - 1].end = w.end
        } else {
            lines.append(Line(speaker: speaker, start: w.start, end: w.end, text: w.text))
        }
    }
    // Parakeet's own punctuation survives on the word text; tidy the spacing.
    return lines.map {
        var l = $0
        l.text = l.text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression).trimmed
        return l
    }
}

private let echoWindow = 6.0

private func words(_ text: String) -> [String] {
    let regex = #/[\p{L}\p{N}']+/#
    return text.lowercased().matches(of: regex).map { String($0.output) }
}

private func pairs(_ w: [String]) -> [String] {
    w.count < 2 ? [] : (1..<w.count).map { "\(w[$0 - 1]) \(w[$0])" }
}

/**
 * A mic line is echo when most of its word pairs were said, in that order, on the call audio within
 * a few seconds. Pairs rather than single words, so a short reply made of the same common words
 * ("yes, I agree that's fine" after "I think that's fine, do you agree?") isn't mistaken for echo.
 */
public func isEcho(_ mic: Line, _ systemLines: [Line]) -> Bool {
    let own = pairs(words(mic.text))
    guard !own.isEmpty else { return false }
    let nearby = Set(systemLines
        .filter { $0.end >= mic.start - echoWindow && $0.start <= mic.end + echoWindow }
        .flatMap { pairs(words($0.text)) })
    return Double(own.filter(nearby.contains).count) / Double(own.count) >= 0.5
}

// MARK: - Names from the conversation

/// Whether a processed recording has a voice nobody has put a name to yet.
public func hasUnnamedVoices(_ dir: URL) -> Bool {
    (try? readJSON(Analysis.self, dir.appendingPathComponent("analysis.json")))?.speakers.contains { $0.suggestion == nil } ?? false
}

/**
 * Step 5: asks the language model who the unrecognised voices are, from what was said, and adds its
 * suggestions to analysis.json. A failure is noted there for the review screen rather than thrown:
 * the names can always be typed.
 */
public func suggestNames(_ dir: URL, config: Config) async {
    let file = dir.appendingPathComponent("analysis.json")
    guard var analysis = try? readJSON(Analysis.self, file), analysis.speakers.contains(where: { $0.suggestion == nil }) else { return }
    do {
        let names = try await namesFromTranscript(config, title: analysis.title, lines: analysis.lines, speakers: analysis.speakers)
        for i in analysis.speakers.indices where analysis.speakers[i].suggestion == nil {
            analysis.speakers[i].suggestion = names[analysis.speakers[i].id]
        }
    } catch is CancellationError {
        return
    } catch let error as URLError where error.code == .cancelled {
        return
    } catch {
        analysis.warnings.append("Name suggestions skipped: \(error.localizedDescription)")
    }
    // The recording may have been discarded meanwhile.
    guard FileManager.default.exists(file) else { return }
    try? writeAtomic(file, (try? encodeJSON(analysis)) ?? "")
}

private let namesSystem = "You work out who is speaking in a meeting transcript."

/// The shape the names come back in. The model's server holds the reply to it.
let namesSchema = #"{"type":"object","properties":{"speakers":{"type":"array","items":{"type":"object","properties":{"speaker":{"type":"string"},"name":{"type":["string","null"]},"quote":{"type":["string","null"]}},"required":["speaker","name","quote"]}}},"required":["speakers"]}"#

private func namesFromTranscript(_ config: Config, title: String, lines: [Line], speakers: [SpeakerInfo]) async throws -> [String: Suggestion] {
    let unknown = speakers.filter { $0.suggestion == nil }.map(\.id)
    func label(_ id: String) -> String {
        id == me ? "\(config.myName) (recorder)" : speakers.first { $0.id == id }?.suggestion?.name ?? "Speaker \(id)"
    }
    let head = ["Meeting title: \(title)", config.jargonLine].filter { !$0.isEmpty }.joined(separator: "\n")
    let task = """
        Some speakers are only labelled "Speaker A", "Speaker B" and so on. For each of them, find their real name if the transcript gives it away: when someone says a name while asking a question and the very next line is that speaker answering, the name is theirs; or they introduce themselves ("Alex here"). Take a name only from words in the transcript. If nothing in the transcript shows the name, the name is null; never guess and never invent one.
        Unidentified speakers: \(unknown.map { "Speaker \($0)" }.joined(separator: ", "))
        Reply as JSON: {"speakers": [{"speaker": "A", "name": the name or null, "quote": the few words from the transcript that show it, or null}]}.
        """
    // People say who they are early on: a call too long for the model keeps its start.
    let room = largestContext(config.llm) - LocalModels.tokens(in: head + task) - replyTokens - 200
    var said: [String] = []
    var used = 0
    for line in lines {
        let text = "\(label(line.speaker)): \(line.text)"
        used += LocalModels.tokens(in: text) + 1
        if used > room, !said.isEmpty { break }
        said.append(text)
    }
    let transcript = said.joined(separator: "\n")
    let prompt = "\(head)\n\nTranscript:\n\(transcript)\n\n\(task)"
    let reply = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + replyTokens + 200) { model, _ in
        try await model.complete([ChatMessage("system", namesSystem), ChatMessage("user", prompt)], schema: namesSchema, think: config.llm.reasoning.names, maxTokens: replyTokens)
    }
    return namesIn(reply, unknown: unknown, transcript: transcript, myName: config.myName)
}

/**
 * The names in the model's reply that can be believed: for a voice that was asked about, made of
 * words that are in the transcript, and not a label, a placeholder or your own name. A small model
 * asked for a name will sometimes make one up; one that was never said is thrown away here.
 */
func namesIn(_ reply: String, unknown: [String], transcript: String, myName: String) -> [String: Suggestion] {
    struct Reply: Decodable {
        struct Guess: Decodable {
            var speaker: String?
            var name: String?
            var quote: String?
        }
        var speakers: [Guess]
    }
    guard let parsed = try? parseJsonObject(Reply.self, reply) else { return [:] }
    // Whole words: "Dan" isn't said by a transcript that has "abundant" in it.
    func words(_ text: String) -> [Substring] { foldedForSearch(text).split { !$0.isLetter && !$0.isNumber } }
    let heard = Set(words(transcript))
    let mine = Set(foldedForSearch(myName).split(separator: " "))
    var names: [String: Suggestion] = [:]
    for guess in parsed.speakers {
        let id = (guess.speaker ?? "").replacingOccurrences(of: #"(?i)^speaker\s+"#, with: "", options: .regularExpression).trimmed.uppercased()
        guard unknown.contains(id), names[id] == nil, let name = guess.name?.trimmed, !name.isEmpty else { continue }
        let folded = foldedForSearch(name)
        guard !["null", "none", "unknown", "n/a", "full name", "the name"].contains(folded), !folded.hasPrefix("speaker"),
              !Set(folded.split(separator: " ")).isSubset(of: mine),
              !words(name).isEmpty, words(name).allSatisfy(heard.contains) else { continue }
        let quote = guess.quote?.trimmed ?? ""
        names[id] = Suggestion(name: name, how: .transcript, detail: ["null", "none"].contains(quote.lowercased()) ? "" : quote)
    }
    return names
}
