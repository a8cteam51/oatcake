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
    /// Recognised from before, guessed from the conversation, or named by you in the live transcript.
    public enum How: String, Codable, Sendable { case voice, transcript, live }
    public var name: String
    public var how: How
    public var detail: String
    /// How close a voice match is (0–1). nil for a name from the conversation, and in analyses made before this was kept.
    public var score: Double? = nil
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
    /// Why the language model's name suggestions were skipped, when they were.
    public var nameSuggestionError: String? = nil
}

extension Analysis {
    /// How earlier versions noted skipped name suggestions: as one of the warnings.
    private static let skippedNames = "Name suggestions skipped: "

    // Read field by field so that an analysis.json written by an earlier version still opens: it
    // has no nameSuggestionError, and says the same thing as a warning, which is moved across.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        endedAt = try c.decode(String.self, forKey: .endedAt)
        lines = try c.decode([Line].self, forKey: .lines)
        speakers = try c.decode([SpeakerInfo].self, forKey: .speakers)
        echoLinesRemoved = try c.decode(Int.self, forKey: .echoLinesRemoved)
        me = try c.decodeIfPresent(Me.self, forKey: .me)
        warnings = try c.decode([String].self, forKey: .warnings)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        nameSuggestionError = try c.decodeIfPresent(String.self, forKey: .nameSuggestionError)
        if nameSuggestionError == nil, let old = warnings.firstIndex(where: { $0.hasPrefix(Self.skippedNames) }) {
            nameSuggestionError = String(warnings.remove(at: old).dropFirst(Self.skippedNames.count))
        }
    }
}

/// Where an analysis has got to. The helper does everything up to matching voices; the app does
/// the last, once the helper has finished.
public enum AnalysisStage: String, Codable, CaseIterable, Sendable {
    case downloadingModels, loadingModels
    case transcribingMic, transcribingCall, tellingVoicesApart, matchingVoices, suggestingNames

    /// The five steps shown as "step N of 5".
    public static let steps: [AnalysisStage] = [.transcribingMic, .transcribingCall, .tellingVoicesApart, .matchingVoices, .suggestingNames]

    /// Whether this is one of the five counted steps, rather than getting the speech models ready.
    public var isStep: Bool { Self.steps.contains(self) }

    /// 1 to 5; downloads and model loading count as step 1.
    public var number: Int { (Self.steps.firstIndex(of: self) ?? 0) + 1 }

    /// What the screen says while it's going on.
    public var title: String {
        switch self {
        case .downloadingModels: "Downloading speech models (about 500 MB, first run only)"
        case .loadingModels: "Loading speech models"
        case .transcribingMic: "Transcribing your microphone"
        case .transcribingCall: "Transcribing the call audio"
        case .tellingVoicesApart: "Telling voices apart"
        case .matchingVoices: "Matching voices"
        case .suggestingNames: "Suggesting names from the conversation"
        }
    }
}

/// What kind of thing stopped an analysis, for saying it in plain words. The raw message goes with it.
public enum AnalysisFailure: String, Codable, Sendable {
    /// call.json or meta.json couldn't be read.
    case unreadableRecording
    /// A file the analysis needed wasn't there (one of the tracks).
    case missingAudio
    /// The speech models couldn't be downloaded or loaded.
    case speechModels
    /// The helper process went without saying why (the app's own finding, not the helper's).
    case helperStopped
    case other
}

/// An analysis failure that knows what kind it is.
struct AnalysisError: LocalizedError {
    var failure: AnalysisFailure
    var underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// What kind of failure an error from `analyse` is.
public func analysisFailure(_ error: Error) -> AnalysisFailure {
    if let known = error as? AnalysisError { return known.failure }
    let missing: [CocoaError.Code] = [.fileNoSuchFile, .fileReadNoSuchFile]
    if let cocoa = error as? CocoaError, missing.contains(cocoa.code) { return .missingAudio }
    return .other
}

/// Runs one part of the analysis, marking whatever it throws as that kind of failure.
private func during<T>(_ failure: AnalysisFailure, _ work: () async throws -> T) async throws -> T {
    do { return try await work() } catch { throw AnalysisError(failure: failure, underlying: error) }
}

/// One progress message from the analysis helper (a JSON line on its standard output).
public struct AnalysisProgress: Codable, Equatable, Sendable {
    public var stage: AnalysisStage?
    public var fraction: Double?
    public var done: Bool?
    public var error: String?
    /// What kind of failure `error` is.
    public var failure: AnalysisFailure?
    public init(stage: AnalysisStage? = nil, fraction: Double? = nil, done: Bool? = nil, error: String? = nil, failure: AnalysisFailure? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.done = done
        self.error = error
        self.failure = failure
    }
}

public func analyse(_ dir: URL, config: Config = Config.load(), voiceprints file: URL = Paths.voiceprints,
                    report: @escaping (AnalysisProgress) -> Void) async throws {
    let (call, meta) = try await during(.unreadableRecording) {
        (try readJSON(CallInfo.self, dir.appendingPathComponent("call.json")), try readJSON(RecorderMeta.self, dir.appendingPathComponent("meta.json")))
    }
    // A track that can't be read stops the analysis (missingAudio, when it isn't there): taken for
    // silence, the call would come out with no lines and could be saved that way, its audio deleted.
    // Mapped, not read: the microphone's floats are let go before the call audio's are made, and its
    // clips are cut from the mapped samples at the end.
    let micTrack = try PcmFile(dir.appendingPathComponent(RecorderFile.micTrack))
    let systemTrack = try PcmFile(dir.appendingPathComponent(RecorderFile.systemTrack))

    report(.init(stage: SpeechModels.needsDownload(config.asrModel) ? .downloadingModels : .loadingModels))
    let (transcriber, diarizer) = try await during(.speechModels) {
        (try await SpeechModels.loadTranscriber(config.asrModel), try await SpeechModels.loadDiarizer())
    }

    report(.init(stage: .transcribingMic, fraction: 0))
    let micLines = try await transcriber.transcribe(micTrack.samples()) { report(.init(stage: .transcribingMic, fraction: $0)) }
        .map { Line(speaker: me, start: $0.start + meta.micOffset, end: $0.end + meta.micOffset, text: $0.text) }

    report(.init(stage: .transcribingCall, fraction: 0))
    let system = systemTrack.samples()
    let systemUtterances = try await transcriber.transcribe(system) { report(.init(stage: .transcribingCall, fraction: $0)) }

    report(.init(stage: .tellingVoicesApart))
    let (turns, prints) = systemUtterances.isEmpty ? ([], [:]) : try await diarize(system, diarizer: diarizer)
    let letters = speakerLetters(turns)
    let systemLines = systemUtterances
        .flatMap { splitBySpeaker($0, turns: turns, letters: letters) }
        .map { Line(speaker: $0.speaker, start: $0.start + meta.systemOffset, end: $0.end + meta.systemOffset, text: $0.text) }

    // On speakers, the mic also hears the other side. Drop mic lines that repeat call audio.
    let keptMic = micLines.filter { !isEcho($0, systemLines) }
    let lines = (keptMic + systemLines).sorted { $0.start < $1.start }

    report(.init(stage: .matchingVoices))
    let clips = dir.appendingPathComponent("clips", isDirectory: true)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    let voiceprints = Voiceprints.load(file)
    let byLetter = Dictionary(letters.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
    let given = liveNameSuggestions(LiveNames.load(dir), turns: turns, letters: letters)
    // From the lines rather than the turns: when diarisation finds nothing, the call audio is all
    // speaker "A", and it still needs a card in review (or its lines would be dropped on save).
    var seen = Set<String>()
    let speakers: [SpeakerInfo] = try systemLines.map(\.speaker).filter { seen.insert($0).inserted }.map { id in
        let own = turns.filter { letters[$0.speaker] == id }
        let embedding = byLetter[id].flatMap { prints[$0] }
        let voice = embedding.flatMap { voiceprints.match($0) }
        let quotes = try clipsFor(systemLines.filter { $0.speaker == id }, prefix: id, offset: meta.systemOffset, into: clips) { slice(system, $0, $1) }
        let seconds = own.isEmpty
            ? systemLines.filter { $0.speaker == id }.reduce(0) { $0 + $1.end - $1.start }
            : own.reduce(0) { $0 + $1.end - $1.start }
        // What you said during the call comes before what the voice sounds like.
        return SpeakerInfo(id: id, seconds: seconds, embedding: embedding,
                           suggestion: given[id] ?? voice.map { Suggestion(name: $0.name, how: .voice, detail: String(format: "voice match %.2f", $0.score), score: Double($0.score)) },
                           quotes: quotes)
    }

    // A few clips of your own voice, for review.
    let meInfo = Analysis.Me(seconds: keptMic.reduce(0) { $0 + $1.end - $1.start },
                             quotes: try clipsFor(keptMic, prefix: "me", offset: meta.micOffset, into: clips) { ArraySlice(micTrack.samples($0, $1)) })

    let analysis = Analysis(title: call.title, startedAt: meta.startedAt, endedAt: meta.endedAt, lines: lines,
                            speakers: speakers.sorted { $0.seconds > $1.seconds },
                            echoLinesRemoved: micLines.count - keptMic.count, me: meInfo, warnings: warnings(meta),
                            embeddingModel: voiceprintModel)
    // Before analysis.json, so a quit can't leave the app's part (Recordings.lastStepFile) unmarked.
    FileManager.default.createFile(atPath: dir.appendingPathComponent(Recordings.lastStepFile).path, contents: nil)
    try writeAtomic(dir.appendingPathComponent("analysis.json"), try encodeJSON(analysis))
}

/// What Who's who says about the recording itself.
func warnings(_ meta: RecorderMeta) -> [String] {
    meta.interrupted == true
        ? ["Recording stopped unexpectedly, so your lines may be slightly out of step with the call’s."]
        : []
}

/**
 * The voices you named in the live transcript. A line counts towards the voice that said most of it
 * (when one did: a line two people shared says nothing about either), and a voice takes the name it
 * was given for the most of its time. Times are in the call audio, as the turns are.
 */
func liveNameSuggestions(_ given: [LiveName], turns: [Turn], letters: [String: String]) -> [String: Suggestion] {
    var votes: [String: [String: Double]] = [:]
    for line in given {
        var heard: [String: Double] = [:]
        // No turns: the call audio is all one voice, "A".
        if turns.isEmpty { heard["A"] = line.end - line.start }
        for turn in turns {
            let overlap = min(line.end, turn.end) - max(line.start, turn.start)
            if overlap > 0, let letter = letters[turn.speaker] { heard[letter, default: 0] += overlap }
        }
        guard let voice = heard.max(by: { $0.value < $1.value }), voice.value > 0,
              voice.value >= 0.6 * heard.values.reduce(0, +) else { continue }
        votes[voice.key, default: [:]][line.name, default: 0] += voice.value
    }
    return votes.compactMapValues { names in
        names.max { $0.value < $1.value }.map { Suggestion(name: $0.key, how: .live, detail: "") }
    }
}

/// The three longest lines of at least 1.5 s, in time order, each with a clip of up to 10 s.
/// `audio` gives the track's samples between two times in seconds.
private func clipsFor(_ lines: [Line], prefix: String, offset: Double, into dir: URL,
                      audio: (Double, Double) -> ArraySlice<Float>) throws -> [Quote] {
    let chosen = lines.filter { $0.end - $0.start >= 1.5 }.sorted { $0.text.count > $1.text.count }.prefix(3).sorted { $0.start < $1.start }
    return try chosen.enumerated().map { i, line in
        let clip = dir.appendingPathComponent("\(prefix)-\(i + 1).wav")
        let from = line.start - offset
        try writeWav(clip, audio(from, min(from + 10, line.end - offset)))
        return Quote(text: line.text, start: line.start, end: line.end, clip: clip.path)
    }
}

/// A, B … Z, then AA, AB …: a call with more than 26 voices doesn't give two of them the same letter.
func speakerLetter(_ index: Int) -> String {
    let letter = String(UnicodeScalar(UInt8(65 + index % 26)))
    return index < 26 ? letter : speakerLetter(index / 26 - 1) + letter
}

/// Letters by order of first appearance: A speaks first.
func speakerLetters(_ turns: [Turn]) -> [String: String] {
    var letters: [String: String] = [:]
    for turn in turns.sorted(by: { $0.start < $1.start }) where letters[turn.speaker] == nil {
        letters[turn.speaker] = speakerLetter(letters.count)
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
    // Without each word's time (SenseVoice), the whole stretch goes to whoever spoke most of it.
    if u.words.isEmpty {
        var spoke: [String: Double] = [:]
        for t in turns { spoke[t.speaker, default: 0] += max(0, min(t.end, u.end) - max(t.start, u.start)) }
        if let most = spoke.filter({ $0.value > 0 }).max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return [Line(speaker: letters[most.key] ?? "A", start: u.start, end: u.end, text: u.text)]
        }
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

let echoWindow = 6.0

/// The words in a line, for comparing lines. Chinese and Japanese aren't written with spaces between
/// words, so each of their characters counts as one: otherwise a whole clause would be a "word", and
/// an echo heard slightly differently on the mic would never match.
func words(_ text: String) -> [String] {
    var found: [String] = []
    var word = ""
    for ch in text.lowercased() {
        if ch.unicodeScalars.allSatisfy(isHanOrKana) {
            if !word.isEmpty { found.append(word) }
            word = ""
            found.append(String(ch))
        } else if ch.isLetter || ch.isNumber || ch == "'" {
            word.append(ch)
        } else if !word.isEmpty {
            found.append(word)
            word = ""
        }
    }
    if !word.isEmpty { found.append(word) }
    return found
}

private func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    // Hiragana and katakana (not their punctuation, ゠ and ・), half-width katakana, and Han.
    case 0x3040...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0xFF66...0xFF9D, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: true
    default: false
    }
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
        analysis.nameSuggestionError = error.localizedDescription
    }
    // The recording may have been discarded meanwhile.
    guard FileManager.default.exists(file), let text = try? encodeJSON(analysis) else { return }
    try? writeAtomic(file, text)
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
        Some speakers are only labelled "Speaker A", "Speaker B" and so on. For each of them, find their real name if the transcript gives it away: when someone says a name while asking a question and the very next line is that speaker answering, the name is theirs; or they introduce themselves ("Jane here"). Take a name only from words in the transcript. If nothing in the transcript shows the name, the name is null; never guess and never invent one.
        Unidentified speakers: \(unknown.map { "Speaker \($0)" }.joined(separator: ", "))
        Reply as JSON: {"speakers": [{"speaker": "A", "name": the name or null, "quote": the few words from the transcript that show it, or null}]}.
        """
    // People say who they are early on: a call too long for the model keeps its start.
    let reply = replyRoom(config.llm)
    let room = largestContext(config.llm) - LocalModels.tokens(in: head + task) - reply - 200
    var said: [String] = []
    var spoken: [String] = []
    var used = 0
    for line in lines {
        let text = "\(label(line.speaker)): \(line.text)"
        used += LocalModels.tokens(in: text) + 1
        if used > room, !said.isEmpty { break }
        said.append(text)
        spoken.append(line.text)
    }
    let transcript = said.joined(separator: "\n")
    let prompt = "\(head)\n\nTranscript:\n\(transcript)\n\n\(task)"
    let answer = try await withModel(config.llm, tokens: LocalModels.tokens(in: prompt) + reply + 200) { model, _ in
        try await model.complete([ChatMessage("system", namesSystem), ChatMessage("user", prompt)], schema: namesSchema, think: config.llm.reasoning.names, maxTokens: reply)
    }
    // Checked against the words alone: a name that's only there as someone else's label wasn't said.
    return namesIn(answer, unknown: unknown, transcript: spoken.joined(separator: "\n"), myName: config.myName)
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
    // Whole words: "Smith" isn't said by a transcript that has "blacksmith" in it.
    func words(_ text: String) -> [Substring] { foldedForSearch(text).split { !$0.isLetter && !$0.isNumber } }
    let heard = Set(words(transcript))
    let mine = Set(foldedForSearch(myName).split(separator: " "))
    var names: [String: Suggestion] = [:]
    for guess in parsed.speakers {
        let id = (guess.speaker ?? "").replacingOccurrences(of: #"(?i)^speaker\s+"#, with: "", options: .regularExpression).trimmed.uppercased()
        guard unknown.contains(id), names[id] == nil, let name = guess.name?.trimmed, !name.isEmpty else { continue }
        let folded = foldedForSearch(name)
        guard !wordsForNothing.contains(folded), !["full name", "the name"].contains(folded), !folded.hasPrefix("speaker"),
              !Set(folded.split(separator: " ")).isSubset(of: mine),
              !words(name).isEmpty, words(name).allSatisfy(heard.contains)
                  // Chinese and Japanese have no spaces to find a whole word by: the name as written will do.
                  || name.unicodeScalars.contains(where: isHanOrKana) && foldedForSearch(transcript).contains(folded) else { continue }
        let quote = guess.quote?.trimmed ?? ""
        names[id] = Suggestion(name: name, how: .transcript, detail: wordsForNothing.contains(quote.lowercased()) ? "" : quote)
    }
    return names
}
