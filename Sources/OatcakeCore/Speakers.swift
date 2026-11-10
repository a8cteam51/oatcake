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
    let result = try await diarizer.process(audio: samples)
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
    static func load() -> Voiceprints {
        guard let prints = tryJSON(Voiceprints.self, Paths.voiceprints) else { return Voiceprints(model: voiceprintModel, people: [:]) }
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
    var prints = Voiceprints.load()
    for entry in entries {
        var person = prints.people[entry.name] ?? Voiceprints.Person(samples: [])
        person.samples.append(.init(embedding: entry.embedding, call: call, at: isoString(Date())))
        person.samples = Array(person.samples.suffix(maxSamplesPerPerson))
        prints.people[entry.name] = person
    }
    let encoder = JSONEncoder()
    try writeAtomic(Paths.voiceprints, String(decoding: try encoder.encode(prints), as: UTF8.self) + "\n")
}
