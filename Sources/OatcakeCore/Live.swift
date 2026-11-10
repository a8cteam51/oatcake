// The live transcript: while a call is being recorded, a helper process (Oatcake --live <recording
// folder>) reads the audio as the recorder writes it and prints each stretch of speech once it's
// finished, as JSON lines. Who said what on the call side is worked out after the call, as before.

import Foundation

/// One line of the live transcript: what was heard on your microphone, or on the call audio.
public struct LiveTranscriptLine: Codable, Equatable, Identifiable, Sendable {
    public enum Track: String, Codable, Sendable { case mic, system }
    public var track: Track
    /// Seconds into the track, which is the time into the call to within a moment.
    public var start: Double
    public var end: Double
    public var text: String
    public var id: String { "\(track.rawValue) \(start)" }

    public init(track: Track, start: Double, end: Double, text: String) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
    }
}

/// What the live helper prints: what it's doing, a line, or why it stopped.
public struct LiveEvent: Codable, Sendable {
    public var status: String?
    public var line: LiveTranscriptLine?
    public var error: String?
    public init(status: String? = nil, line: LiveTranscriptLine? = nil, error: String? = nil) {
        self.status = status
        self.line = line
        self.error = error
    }
}

/// The lines in the order they were said, without microphone lines that only repeat the call audio
/// (the other side coming out of your speakers).
public func liveTranscript(_ lines: [LiveTranscriptLine]) -> [LiveTranscriptLine] {
    let call = lines.filter { $0.track == .system }.map { Line(speaker: "A", start: $0.start, end: $0.end, text: $0.text) }
    return lines
        .filter { $0.track == .system || !isEcho(Line(speaker: me, start: $0.start, end: $0.end, text: $0.text), call) }
        .sorted { $0.start < $1.start }
}

/// Stand-ins for whoever is on the call side of the live transcript: nobody could mistake one for a
/// real name, and the real ones arrive after the call.
public let callPlaceholders = [
    "Mystery Guest", "Speaker McSpeakerface", "Name Pending", "Voice To Be Named", "Captain Placeholder", "The Other End",
    "Somebody Important", "Guest Star", "To Be Announced", "Whoever That Is", "Unnamed Legend", "A Voice On The Call",
]

/**
 * A stand-in for whoever said one line on the call side. Every line gets its own, picked at random
 * the first time the line is shown and kept for it from then on, and never the one the line before
 * got, so each turn reads as someone new until the real names arrive. Only the call being recorded
 * is remembered.
 */
public func callPlaceholder(for recording: String, lineAt start: Double) -> String {
    placeholderLock.withLock {
        if chosenFor != recording {
            chosenFor = recording
            chosenPlaceholders = [:]
            lastPlaceholder = nil
        }
        let line = Int((start * 10).rounded())
        if let chosen = chosenPlaceholders[line] { return chosen }
        let chosen = callPlaceholders.filter { $0 != lastPlaceholder }.randomElement()!
        chosenPlaceholders[line] = chosen
        lastPlaceholder = chosen
        return chosen
    }
}
private let placeholderLock = NSLock()
nonisolated(unsafe) private var chosenFor = ""
nonisolated(unsafe) private var chosenPlaceholders: [Int: String] = [:]
nonisolated(unsafe) private var lastPlaceholder: String?

/**
 * Transcribes a recording while it's being made, reporting each line as it's finished. Returns once
 * the recorder has finished (meta.json is there), the recording has been thrown away, or Oatcake
 * itself has gone.
 */
public func transcribeLive(_ dir: URL, report: @escaping (LiveEvent) -> Void) async throws {
    let config = Config.load()
    report(LiveEvent(status: SpeechModels.needsDownload(config.asrModel) ? "Downloading the speech models (about 500 MB, first time only)" : "Loading the speech models"))
    let transcriber = try await SpeechModels.loadTranscriber(config.asrModel)
    report(LiveEvent(status: "Listening"))
    // Samples of each track already dealt with. The call audio first, so a line of yours that only
    // echoes it is recognised as an echo straight away.
    var done: [(track: LiveTranscriptLine.Track, file: String, samples: Int)] = [(.system, "system.pcm", 0), (.mic, "mic.pcm", 0)]
    let oatcake = getppid()
    while true {
        guard FileManager.default.exists(dir), getppid() == oatcake else { return }
        let finished = FileManager.default.exists(dir.appendingPathComponent("meta.json"))
        for i in done.indices {
            let fresh = readPcm(dir.appendingPathComponent(done[i].file), fromSample: done[i].samples)
            guard fresh.count >= sampleRate / 2 else { continue }
            let (utterances, consumed) = try await transcriber.transcribeFinished(fresh)
            let offset = Double(done[i].samples) / Double(sampleRate)
            for u in utterances {
                report(LiveEvent(line: LiveTranscriptLine(track: done[i].track, start: u.start + offset, end: u.end + offset, text: u.text)))
            }
            done[i].samples += consumed
        }
        if finished { return }
        try await Task.sleep(for: .seconds(1.5))
    }
}
