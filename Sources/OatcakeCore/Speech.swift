// The speech models: FluidAudio's Core ML builds of Silero (finds speech), Parakeet (speech to
// text), and pyannote + WeSpeaker (who spoke when, and voice fingerprints). They run on the
// Neural Engine and download from Hugging Face on first use, about 500 MB.

import FluidAudio
import Foundation

public enum SpeechModels {
    public struct AsrChoice: Sendable {
        public let key: String
        public let title: String
        public let detail: String
        let version: AsrModelVersion
    }

    /// The transcription models Settings offers.
    public static let asr: [AsrChoice] = [
        AsrChoice(key: "parakeet-en", title: "Parakeet English", detail: "English only. The most accurate for English calls.", version: .v2),
        AsrChoice(key: "parakeet-multilingual", title: "Parakeet — 25 European languages",
                  detail: "Detects the language of each call.", version: .ultra),
    ]
    public static let defaultAsr = "parakeet-en"

    /// A config value, including the Electron version's names for the same two choices.
    public static func asrChoice(_ key: String) -> AsrChoice {
        switch key {
        case "parakeet-multilingual", "parakeet-tdt-v3": asr[1]
        default: asr[0]
        }
    }

    static let root = Paths.models.appendingPathComponent("FluidAudio", isDirectory: true)
    static func asrDirectory(_ version: AsrModelVersion) -> URL {
        root.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }
    static let diarizerDirectory = root.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)

    /// Whether anything still has to be downloaded for this transcription model.
    static func needsDownload(_ key: String) -> Bool {
        let version = asrChoice(key).version
        return !AsrModels.modelsExist(at: asrDirectory(version), version: version)
            || !FileManager.default.exists(root.appendingPathComponent("Models/silero-vad"))
            || !FileManager.default.exists(diarizerDirectory)
    }

    static func loadTranscriber(_ key: String) async throws -> Transcriber {
        let version = asrChoice(key).version
        let vad = try await VadManager(config: .default, modelDirectory: root)
        let models = try await AsrModels.downloadAndLoad(to: asrDirectory(version), version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        return Transcriber(vad: vad, asr: asr)
    }

    static func loadDiarizer() async throws -> OfflineDiarizerManager {
        var config = OfflineDiarizerConfig()
        // One speaker at a time, so every word of the transcript gets exactly one.
        config.postProcessing.exclusiveSegments = true
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: diarizerDirectory)
        return manager
    }

    /// The Electron version's sherpa-onnx models (about 700 MB), which nothing uses any more.
    public static func removeOldModels() {
        let old = [
            "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming",
            "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            "silero_vad.onnx",
            "sherpa-onnx-pyannote-segmentation-3-0",
            "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
        ]
        for name in old { try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(name)) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? [] where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(name))
        }
    }
}

public struct Word: Sendable {
    public var text: String
    /// Seconds from the start of the track.
    public var start: Double
    public var end: Double
}

public struct Utterance: Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
}

/// Silero finds the stretches of speech (up to 14 s each), and Parakeet decodes each one.
final class Transcriber {
    private let vad: VadManager
    private let asr: AsrManager

    init(vad: VadManager, asr: AsrManager) {
        self.vad = vad
        self.asr = asr
    }

    func transcribe(_ samples: [Float], progress: (Double) -> Void) async throws -> [Utterance] {
        guard !samples.isEmpty else { return [] }
        var segmentation = VadSegmentationConfig.default
        segmentation.minSpeechDuration = 0.25
        segmentation.minSilenceDuration = 0.4
        segmentation.maxSpeechDuration = 14
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
        var utterances: [Utterance] = []
        for (i, segment) in segments.enumerated() {
            var chunk = Array(slice(samples, segment.startTime, segment.endTime))
            // Very short stretches are padded with silence up to the model's minimum.
            if chunk.count < minimum { chunk += [Float](repeating: 0, count: minimum - chunk.count) }
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(chunk, decoderState: &state)
            let text = result.text.trimmed
            if !text.isEmpty {
                let words = buildWordTimings(from: result.tokenTimings ?? []).map {
                    Word(text: $0.word, start: segment.startTime + $0.startTime, end: segment.startTime + $0.endTime)
                }
                utterances.append(Utterance(start: segment.startTime, end: segment.endTime, text: text, words: words))
            }
            if i % 10 == 0 { progress(Double(i) / Double(segments.count)) }
        }
        progress(1)
        return utterances
    }
}
