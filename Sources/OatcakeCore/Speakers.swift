import FluidAudio
import Foundation

public struct Turn: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
}

/// Turns with less speech than this go to the closest voice with more.
private let minSpeakerSeconds = 5.0

/**
 * Splits the call audio into turns by voice, and gives each voice a fingerprint. Speaker IDs only
 * mean something within this call.
 *
 * FluidAudio's batch pipeline (pyannote segmentation, WeSpeaker fingerprints, VBx clustering).
 * On AMI meetings with known speakers it found the right number of people at 76–78% purity, where
 * the Electron version's sherpa-onnx pipeline with its own merge step found one too many at 59%.
 */
func diarize(_ samples: [Float], diarizer: OfflineDiarizerManager) async throws -> (turns: [Turn], prints: [String: [Float]]) {
    let result: DiarizationResult
    do {
        result = try await diarizer.process(audio: samples)
    } catch OfflineDiarizationError.noSpeechDetected {
        // The transcriber heard something the voice model doesn't count as speech (a quiet call,
        // background noise): the call audio is one voice, as when nobody else spoke.
        return ([], [:])
    }
    var turns = result.segments.map { Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
    var prints = (result.speakerDatabase ?? [:]).mapValues(normalise)

    // A voice with only a few seconds of speech is usually a stray piece of someone else's.
    let seconds = Dictionary(turns.map { ($0.speaker, $0.end - $0.start) }, uniquingKeysWith: +)
    let main = prints.filter { (seconds[$0.key] ?? 0) >= minSpeakerSeconds }
    guard !main.isEmpty else { return (turns, prints) }
    for (id, print) in prints where main[id] == nil {
        if let closest = main.max(by: { cosine(print, $0.value) < cosine(print, $1.value) }) {
            for i in turns.indices where turns[i].speaker == id { turns[i].speaker = closest.key }
        }
        prints.removeValue(forKey: id)
    }
    return (turns, prints)
}

func normalise(_ v: [Float]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? v.map { $0 / norm } : v
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return -1 }
    return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

// MARK: - Voiceprints

// Several fingerprints per person (one per call, newest kept), because people sound different on
// Zoom, Meet and a laptop mic.

/// Fingerprints only match ones from the same model.
public let voiceprintModel = "wespeaker-v2"
private let maxSamplesPerPerson = 10
// Measured on AMI ES2004a against ES2004c (same four people): the same person scored 0.85–0.95,
// different people 0.34 at most.
private let matchThreshold: Float = 0.6
private let matchMargin: Float = 0.1

struct Voiceprints: Codable {
    struct Sample: Codable {
        var embedding: [Float]
        var call: String
        var at: String
    }
    struct Person: Codable { var samples: [Sample] }

    var model: String
    var people: [String: Person]

    /// A file from another fingerprint model (the Electron version's CAM++) keeps its names, so
    /// they're still suggested in review, but not its fingerprints.
    static func load(_ file: URL = Paths.voiceprints) -> Voiceprints {
        guard let prints = tryJSON(Voiceprints.self, file) else { return Voiceprints(model: voiceprintModel, people: [:]) }
        if prints.model == voiceprintModel { return prints }
        return Voiceprints(model: voiceprintModel, people: prints.people.mapValues { _ in Person(samples: []) })
    }

    /// Best voice match, only when it clears the threshold and beats the runner-up by the margin.
    func match(_ embedding: [Float]) -> (name: String, score: Float)? {
        let scores = people.compactMap { name, person -> (String, Float)? in
            person.samples.map { cosine(embedding, $0.embedding) }.max().map { (name, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= matchThreshold else { return nil }
        if scores.count > 1, best.1 - scores[1].1 < matchMargin { return nil }
        return best
    }
}

public func knownPeople() -> [String] {
    Voiceprints.load().people.keys.sorted()
}

func addVoiceprints(_ entries: [(name: String, embedding: [Float])], call: String) throws {
    // Nothing new: leave the file as it is (an Electron-era file keeps its old fingerprints on disk).
    guard !entries.isEmpty else { return }
    var prints = Voiceprints.load()
    for entry in entries {
        var person = prints.people[entry.name] ?? Voiceprints.Person(samples: [])
        // One fingerprint per call: saving the same recording again replaces its own.
        person.samples.removeAll { $0.call == call }
        person.samples.append(.init(embedding: entry.embedding, call: call, at: isoString(Date())))
        person.samples = Array(person.samples.suffix(maxSamplesPerPerson))
        prints.people[entry.name] = person
    }
    try prints.save()
}

extension Voiceprints {
    func save(_ file: URL = Paths.voiceprints) throws {
        try writeAtomic(file, String(decoding: try JSONEncoder().encode(self), as: UTF8.self) + "\n")
    }
}

/// A person Oatcake knows by voice, for Settings › People.
public struct KnownVoice: Identifiable, Equatable, Sendable {
    public var name: String
    /// Calls their voice was saved from; 0 for a name kept from the Electron version, whose
    /// fingerprints no longer match.
    public var calls: Int
    public var lastSaved: Date?
    public var id: String { name }
}

public func knownVoices(_ file: URL = Paths.voiceprints) -> [KnownVoice] {
    Voiceprints.load(file).people.map { name, person in
        KnownVoice(name: name, calls: person.samples.count, lastSaved: person.samples.compactMap { parseISO($0.at) }.max())
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/**
 * Renames a person's voice ("Nate" to "Nate Allen"). When someone already has the new name, the two
 * become one person with both sets of fingerprints (newest kept), rather than two people with the same
 * voice, which would stop either being recognised. Meetings already saved keep the name they had.
 */
public func renameVoice(_ name: String, to newName: String, file: URL = Paths.voiceprints) throws {
    let clean = newName.trimmed
    guard !clean.isEmpty else { throw OatcakeError("Give them a name.") }
    var prints = Voiceprints.load(file)
    guard let person = prints.people.removeValue(forKey: name) else { throw OatcakeError("Oatcake doesn't know \(name)'s voice.") }
    var merged = prints.people[clean] ?? Voiceprints.Person(samples: [])
    merged.samples = Array((merged.samples + person.samples).sorted { $0.at < $1.at }.suffix(maxSamplesPerPerson))
    prints.people[clean] = merged
    try prints.save(file)
}

/// Forgets a person's voice: Oatcake no longer recognises them or suggests their name.
public func forgetVoice(_ name: String, file: URL = Paths.voiceprints) throws {
    var prints = Voiceprints.load(file)
    prints.people.removeValue(forKey: name)
    try prints.save(file)
}
