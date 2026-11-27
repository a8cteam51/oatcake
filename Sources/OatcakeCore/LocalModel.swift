// The language model that writes summaries, suggests names and answers questions runs on this Mac.
// It's one of Qwen's or Google's open models (Oatcake starts with the best of Qwen's that fits this
// Mac's memory), run by llama.cpp's server: a
// small program inside Oatcake that is started on this Mac's own address (127.0.0.1) when there's
// something to write and stopped when there's been nothing for a while. The model's file is downloaded once, from a fixed revision on
// Hugging Face, and checked against its SHA-256 when it arrives and again whenever its size or
// modification date has changed since. Nothing is sent anywhere.

import CryptoKit
import Foundation
import Security

/// How a model's makers say to sample from it, for one way of asking. Every model takes min_p 0; what
/// differs is how hot it runs, how many of the likeliest tokens it picks from, and how much it's kept
/// from repeating itself.
public struct Sampling: Sendable, Equatable {
    let temperature: Double
    let topP: Double
    let topK: Int
    let presencePenalty: Double
}

public struct LocalModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// What Settings says about it, so the choice can be made without knowing the names.
    public let detail: String
    public let file: String
    public let url: String
    public let sha256: String
    public let bytes: Int64
    /// What it needs in memory, in GB: this much to load, plus this much for every thousand tokens it
    /// can hold in mind at once. Measured with llama.cpp on Apple silicon.
    let baseMemory: Double
    let memoryPerThousandTokens: Double
    /// The tokens it reads as it was trained to. Beyond them the window is stretched (YaRN), which
    /// Qwen says to do only when a text needs it.
    let nativeContext: Int
    /// Its makers' sampling with reasoning on, and with it off.
    let thinking: Sampling
    let direct: Sampling
    /// Room for one request's reasoning and reply together. A model that reasons at length needs
    /// more, or its reply is cut off.
    let replyTokens: Int
    /// Kept for the people who chose it: a newer model does its job better, and it's never recommended.
    public let legacy: Bool
    /// Which tasks it reasons through, as it's set up when it's chosen: what suited it in Oatcake's
    /// tests, which looked for a summary within two minutes on a 2023 MacBook Pro (M3 Pro).
    public let reasoning: LlmConfig.Reasoning

    public var downloadSize: String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// GB of memory with room for `context` tokens.
    func memory(context: Int) -> Double { baseMemory + memoryPerThousandTokens * Double(context) / 1000 }

    /// How many times over a window stretches the positions the model was trained on (YaRN): 1 when
    /// it's within them. Only for a text that needs it, and no further than it needs (Qwen's own advice).
    func stretch(_ context: Int) -> Int { max(1, Int((Double(context) / Double(nativeContext)).rounded(.up))) }

    /// Whether a server running with one window can do a job that needs another: it has to be big
    /// enough, and stretched just as far as the job needs. A stretched window reads a shorter text
    /// a little worse, so a job that fits the model's own window never borrows one.
    func serves(running: Int, needed: Int) -> Bool { running >= needed && stretch(running) == stretch(needed) }
}

/// Qwen3's sampling (its model cards): cooler with reasoning on than off.
private let qwen3 = (thinking: Sampling(temperature: 0.6, topP: 0.95, topK: 20, presencePenalty: 1.5),
                     direct: Sampling(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5))

/// Qwen3.5's and Qwen3.6's (their model cards): hotter with reasoning on.
private let qwen35 = (thinking: Sampling(temperature: 1.0, topP: 0.95, topK: 20, presencePenalty: 1.5),
                      direct: Sampling(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5))

/// Gemma 4's (its model card): the same with reasoning on or off.
private let gemma4 = Sampling(temperature: 1.0, topP: 0.95, topK: 64, presencePenalty: 0)

/// Qwen3.5 and Qwen3.6 reason for 6,000 to 10,000 tokens before a summary: several minutes on a
/// slower Mac, for summaries no better than they write without it. They start with it off, and so
/// does Gemma 4, which took two to three times as long with it on.
private let reasonsNothing = LlmConfig.Reasoning(summary: false, todos: false, names: false, ask: false, sharing: false)

public enum LocalModels {
    /// What a model server of your own is planned for when you haven't said how much it holds:
    /// Qwen3's own window, which most models people run themselves can take.
    public static let nativeContext = 32_768
    static let contexts = [8_192, 12_288, 16_384, 24_576, 32_768, 49_152, 65_536, 98_304, 131_072]

    /// Qwen's newer models first, best first: the first that fits a Mac is the one it starts with,
    /// and Qwen3.5 4B fits every Mac Oatcake runs on. Then Google's Gemma 4, to choose instead, and
    /// Qwen3, kept for those who chose it. Qwen publishes the newer families' weights but not GGUF
    /// files, so theirs are llama.cpp's own conversions (ggml-org), which were checked by converting
    /// Qwen's weights again with llama.cpp's published steps. Gemma's are Google's own.
    public static let all: [LocalModel] = [
        LocalModel(id: "qwen3.6-35b-a3b", title: "Qwen3.6 35B-A3B",
                   detail: "By Alibaba. One of the most accurate in Oatcake’s tests, with full summaries and to-do lists, and quick for its size. 20.5 GB to download; needs a Mac with 32 GB of memory or more.",
                   file: "Qwen3.6-35B-A3B-Q4_K_M.gguf",
                   url: "https://huggingface.co/ggml-org/Qwen3.6-35B-A3B-GGUF/resolve/52f9f9b8052fb9c8b69bba4a95eda0f319ac3d2a/Qwen3.6-35B-A3B-Q4_K_M.gguf",
                   sha256: "f4ffe03c9139e6a905a5d346f77d9fabdd179367c3280dfd005d1e75ca5ed8c8", bytes: 20_542_732_576,
                   baseMemory: 20.9, memoryPerThousandTokens: 0.020, nativeContext: 262_144,
                   thinking: qwen35.thinking, direct: qwen35.direct, replyTokens: 16_384, legacy: false, reasoning: reasonsNothing),
        LocalModel(id: "qwen3.5-4b", title: "Qwen3.5 4B",
                   detail: "By Alibaba. Small and quick, for Macs with less than 32 GB of memory, but it made more mistakes than the larger new models in Oatcake’s tests. As it starts, it leaves voices for you to name rather than suggesting names. 3.0 GB to download.",
                   file: "Qwen3.5-4B-Q4_K_M.gguf",
                   url: "https://huggingface.co/ggml-org/Qwen3.5-4B-GGUF/resolve/8d43d974efc48399cb58957ad49c8b26bf5a109c/Qwen3.5-4B-Q4_K_M.gguf",
                   sha256: "217002fa8008ef4fc6d548353a3aebef055a96e6ff8e0e2c0953ef8254a89c14", bytes: 3_032_091_584,
                   baseMemory: 3.2, memoryPerThousandTokens: 0.033, nativeContext: 262_144,
                   thinking: qwen35.thinking, direct: qwen35.direct, replyTokens: 16_384, legacy: false, reasoning: reasonsNothing),
        LocalModel(id: "gemma-4-26b-a4b", title: "Gemma 4 26B-A4B",
                   detail: "By Google. The quickest in Oatcake’s tests and one of the most accurate, but its summaries are brief and its to-do lists left out a task the others caught. 14.4 GB to download; needs a Mac with 24 GB of memory or more.",
                   file: "gemma-4-26B_q4_0-it.gguf",
                   url: "https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/d1c082be9cf3c8a514acf63b8761f4b41935842e/gemma-4-26B_q4_0-it.gguf",
                   sha256: "3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d", bytes: 14_439_363_584,
                   baseMemory: 15.5, memoryPerThousandTokens: 0.028, nativeContext: 262_144,
                   thinking: gemma4, direct: gemma4, replyTokens: 16_384, legacy: false, reasoning: reasonsNothing),
        LocalModel(id: "gemma-4-12b", title: "Gemma 4 12B",
                   detail: "By Google. Fairly accurate in Oatcake’s tests, with full summaries, but the slowest of these models. 7.0 GB to download; needs a Mac with 16 GB of memory or more.",
                   file: "gemma-4-12b-it-qat-q4_0.gguf",
                   url: "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/29d097773436b69ff9feafd636ab4cf873786537/gemma-4-12b-it-qat-q4_0.gguf",
                   sha256: "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b", bytes: 6_975_879_296,
                   baseMemory: 8.5, memoryPerThousandTokens: 0.022, nativeContext: 262_144,
                   thinking: gemma4, direct: gemma4, replyTokens: 16_384, legacy: false, reasoning: reasonsNothing),
        LocalModel(id: "qwen3-8b", title: "Qwen3 8B",
                   detail: "By Alibaba. Oatcake’s earlier choice for Macs with 16 GB of memory or more. How accurate it was varied widely between Oatcake’s tests, and it’s slower than most of the newer models. 5.0 GB to download.",
                   file: "Qwen3-8B-Q4_K_M.gguf",
                   url: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q4_K_M.gguf",
                   sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785", bytes: 5_027_783_488,
                   baseMemory: 5.0, memoryPerThousandTokens: 0.14, nativeContext: 32_768,
                   thinking: qwen3.thinking, direct: qwen3.direct, replyTokens: replyTokens, legacy: true, reasoning: LlmConfig.Reasoning()),
        LocalModel(id: "qwen3-4b", title: "Qwen3 4B",
                   detail: "By Alibaba. Oatcake’s earlier choice for Macs with 8 GB of memory. It made more mistakes than most of the newer models in Oatcake’s tests. 2.5 GB to download.",
                   file: "Qwen3-4B-Q4_K_M.gguf",
                   url: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf",
                   sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5", bytes: 2_497_280_256,
                   baseMemory: 2.6, memoryPerThousandTokens: 0.14, nativeContext: 32_768,
                   thinking: qwen3.thinking, direct: qwen3.direct, replyTokens: replyTokens, legacy: true, reasoning: LlmConfig.Reasoning()),
    ]

    public static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    /// This Mac's memory in GB.
    public static var physicalMemory: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// The model to start with: the first in the list (they're best first) that isn't kept only for
    /// those who chose it and fits this Mac, or the smallest if none does.
    public static func recommended(memory: Double = physicalMemory) -> LocalModel {
        all.first { !$0.legacy && fits($0, memory: memory) } ?? all.filter { !$0.legacy }.min { $0.baseMemory < $1.baseMemory }!
    }

    /// Whether the model fits this Mac with room for an hour-long call.
    public static func fits(_ model: LocalModel, memory: Double = physicalMemory) -> Bool {
        model.memory(context: 16_384) <= allowed(memory)
    }

    /// The most tokens the model can be given at once on this Mac. The rest of the Mac keeps some
    /// memory back: 6 GB, or 3 GB on a Mac that only has 8.
    public static func maxContext(_ model: LocalModel, memory: Double = physicalMemory) -> Int {
        contexts.last { model.memory(context: $0) <= allowed(memory) } ?? contexts[0]
    }

    private static func allowed(_ memory: Double) -> Double { memory - (memory >= 15.5 ? 6 : 3) }

    /// The smallest window that holds a prompt of this many tokens and its reply.
    public static func context(forTokens tokens: Int) -> Int { contexts.first { $0 >= tokens } ?? contexts.last! }

    /// A rough count of the tokens in a text: English runs at about four characters a token, other
    /// languages at fewer, so this errs on the high side.
    public static func tokens(in text: String) -> Int { text.utf8.count * 10 / bytesPerTenTokens + 1 }

    /// About how much text that many tokens is, by the same measure.
    static func bytes(forTokens tokens: Int) -> Int { tokens * bytesPerTenTokens / 10 }

    /// 3.3 bytes of text to a token.
    private static let bytesPerTenTokens = 33

    /// Where the models' files are kept. The functions below look there unless told another folder (a test's).
    public static var directory: URL { Paths.models.appendingPathComponent("llm", isDirectory: true) }
    public static func file(_ model: LocalModel, in directory: URL = directory) -> URL { directory.appendingPathComponent(model.file) }

    public static func isDownloaded(_ model: LocalModel, in directory: URL = directory) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: file(model, in: directory).path))?[.size] as? Int64) == model.bytes
    }

    /// Whether a download of the model was left part-way: its file so far is still on the disk.
    public static func hasPartialDownload(_ model: LocalModel, in directory: URL = directory) -> Bool {
        FileManager.default.exists(file(model, in: directory).appendingPathExtension("part"))
    }

    /// Removes a model's file (and a download of it that was left part-way).
    public static func remove(_ model: LocalModel, in directory: URL = directory) {
        try? FileManager.default.removeItem(at: file(model, in: directory))
        try? FileManager.default.removeItem(at: file(model, in: directory).appendingPathExtension("part"))
        try? FileManager.default.removeItem(at: checkedNote(model, in: directory))
    }

    /**
     * Checks the model's file against its SHA-256 before it's started, when its size or modification
     * date has changed since the last check that it passed (reading 5 GB every time would hold up
     * every summary). A file that doesn't match is thrown away, to be downloaded again.
     */
    static func verify(_ model: LocalModel, in directory: URL = directory) throws {
        let file = file(model, in: directory)
        guard let stamp = stamp(of: file) else { throw OatcakeError(modelNotDownloadedMessage) }
        if (try? String(contentsOf: checkedNote(model, in: directory), encoding: .utf8)) == stamp { return }
        guard try ModelDownload.sha256(of: file) == model.sha256 else {
            remove(model, in: directory)
            throw OatcakeError("The language model’s file had changed since it was downloaded, so it was thrown away. It’s downloaded again the next time it’s needed.")
        }
        noteChecked(model, in: directory)
    }

    /// Notes the size and modification date of a model's file that has just passed its check.
    static func noteChecked(_ model: LocalModel, in directory: URL = directory) {
        if let stamp = stamp(of: file(model, in: directory)) { try? stamp.write(to: checkedNote(model, in: directory), atomically: true, encoding: .utf8) }
    }

    private static func checkedNote(_ model: LocalModel, in directory: URL) -> URL { file(model, in: directory).appendingPathExtension("checked") }

    private static func stamp(of file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int64, let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size) \(modified.timeIntervalSince1970)"
    }
}

public let modelNotDownloadedMessage = "The language model isn’t downloaded yet. Settings › Models shows how far it has got, and can start it again."

/// Downloads a model's file, carrying on from where an earlier attempt stopped, and checks it's the
/// file that was expected before putting it in place.
// Sendable by arrangement: its state is set up before the download is resumed and after that is only
// touched from the session's own delegate queue, which runs one callback at a time. The continuation
// is the exception, set from the task that waits: it's behind a lock, and whoever takes it resumes it.
public final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModel
    private let part: URL
    private let progress: @Sendable (Double) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var reported = -1.0
    private var failure: Error?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }

    private init(_ model: LocalModel, part: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.part = part
        self.progress = progress
    }

    /// Downloads the model's file to where Oatcake keeps it (`file` is somewhere else only in tests).
    /// While it's on its way it's "<name>.part" beside that; it's only given its name once it's whole
    /// and its SHA-256 is the one expected.
    /// `available` is the room on the disk, in bytes, when a test wants to say.
    public static func fetch(_ model: LocalModel, to file: URL? = nil, available: Int64? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let file = file ?? LocalModels.file(model)
        if ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) == model.bytes { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = file.appendingPathExtension("part")
        // Said before it starts, rather than found out when the disk fills: what's still to come, and a gigabyte to spare.
        let have = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0
        let free = available ?? (try? file.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if have < model.bytes, let free, free < model.bytes - have + 1_000_000_000 {
            let gb = { (bytes: Int64) in String(format: "%.1f GB", Double(bytes) / 1e9) }
            throw OatcakeError("There isn’t room on this Mac to download \(model.title): it needs \(gb(model.bytes - have + 1_000_000_000)) free, and there’s \(gb(max(0, free))). Free some space, then try again.")
        }
        let download = ModelDownload(model, part: part, progress: progress)
        try await download.run()
        guard try sha256(of: download.part) == model.sha256 else {
            try? FileManager.default.removeItem(at: download.part)
            throw OatcakeError("The download of \(model.title) didn’t match its checksum, so it was thrown away. Try again.")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: download.part, to: file)
        LocalModels.noteChecked(model, in: file.deletingLastPathComponent())
        progress(1)
    }

    private func run() async throws {
        guard let url = URL(string: model.url) else { throw OatcakeError("The model’s address isn’t valid.") }
        let have = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0
        if have == model.bytes { return }
        if have > model.bytes { try? FileManager.default.removeItem(at: part) }
        var request = URLRequest(url: url)
        if have > 0, have < model.bytes { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock { continuation = c }
                // Stopped before it began: the cancel may have come before there was anything for
                // it to finish, so it's finished here and never started.
                if Task.isCancelled {
                    takeContinuation()?.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            if status == 206 {
                // Carrying on from the part that's already here.
                let h = try FileHandle(forWritingTo: part)
                received = Int64(try h.seekToEnd())
                handle = h
            } else if status == 200 {
                FileManager.default.createFile(atPath: part.path, contents: nil)
                handle = try FileHandle(forWritingTo: part)
                received = 0
            } else {
                throw OatcakeError("The download of \(model.title) failed (HTTP \(status)).")
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            // Told a thousand times at most, not once for every packet.
            let fraction = min(0.999, Double(received) / Double(model.bytes))
            if fraction - reported >= 0.001 {
                reported = fraction
                progress(fraction)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let continuation = takeContinuation()
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            let stopped = (error as? URLError)?.code == .cancelled
            continuation?.resume(throwing: stopped ? CancellationError() as Error : OatcakeError("The download of \(model.title) stopped: \(error.localizedDescription) It carries on from where it got to when you try again."))
        } else if received != model.bytes {
            continuation?.resume(throwing: OatcakeError("The download of \(model.title) stopped early. It carries on from where it got to when you try again."))
        } else {
            continuation?.resume()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/**
 * Runs llama.cpp's server for one model: started when something needs the model, on this Mac's own
 * address and a port nobody else is using, with a key made up for the occasion, so that a web page
 * or another account on the Mac can't use it. One at a time. A request that needs a bigger window (or the other model) waits for the
 * requests under way to finish, then restarts it.
 */
public actor ModelServer {
    public static let shared = ModelServer()

    private var process: Process?
    private var running: (model: String, context: Int, chat: LocalChat)?
    /// Requests under way. The server isn't restarted, or stopped for being idle, while there are any.
    private var leases = 0
    /// Starting up: nobody else starts it meanwhile.
    private var changing = false
    private var lastUsed = Date()

    /// llama.cpp's server: inside Oatcake.app, or (for a development copy that has none) in the folder OATCAKE_LLAMA_DIR names.
    public static var binary: URL? {
        // The one inside Oatcake.app whenever there is one: the folder named from outside is only for a copy built without.
        let folders = [Bundle.main.resourceURL?.appendingPathComponent("llama", isDirectory: true),
                       ProcessInfo.processInfo.environment["OATCAKE_LLAMA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }]
        return folders.compactMap { $0?.appendingPathComponent("llama-server") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where the note of its process ID and its log go, and where the models' files are: Oatcake's
    /// own folders, except in tests.
    private let pidFile: URL
    let log: URL
    private let data: URL
    private let models: URL

    public init(data: URL = Paths.data, models: URL = LocalModels.directory) {
        self.data = data
        pidFile = Self.pidFile(in: data)
        log = data.appendingPathComponent("model-server.log")
        self.models = models
    }

    private static func pidFile(in data: URL) -> URL { data.appendingPathComponent("model-server.pid") }

    /// The model, loaded with room for at least `context` tokens. It's kept as it is until `release()`.
    func lease(_ model: LocalModel, context: Int) async throws -> LocalChat {
        while true {
            try Task.checkCancellation()
            if !changing {
                if let running, running.model == model.id, model.serves(running: running.context, needed: context), process?.isRunning == true {
                    leases += 1
                    lastUsed = Date()
                    return running.chat
                }
                if leases == 0 { break }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        changing = true
        defer { changing = false }
        let chat = try await start(model, context: context)
        leases += 1
        lastUsed = Date()
        return chat
    }

    func release() {
        leases = max(0, leases - 1)
        lastUsed = Date()
    }

    private func start(_ model: LocalModel, context: Int) async throws -> LocalChat {
        stop()
        Self.stopLeftover(in: data)
        guard let binary = Self.binary else {
            throw OatcakeError("This copy of Oatcake was built without llama.cpp, which runs the language model. Build it with Scripts/bundle.sh.")
        }
        // Only the server inside Oatcake.app is covered by its signature: one named by
        // OATCAKE_LLAMA_DIR is a development copy's own.
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app", binary.path.hasPrefix(app.path + "/") { try Self.checkSealed(app) }
        guard LocalModels.isDownloaded(model, in: models) else { throw OatcakeError(modelNotDownloadedMessage) }
        try LocalModels.verify(model, in: models)

        let port = try Self.freePort()
        let key = UUID().uuidString
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let server = Process()
        server.executableURL = binary
        server.arguments = Self.arguments(model, file: LocalModels.file(model, in: models), port: port, context: context)
        // The key goes in its environment: a command line can be read by every account on the Mac.
        server.environment = ShellEnvironment.childEnvironment().merging(["LLAMA_API_KEY": key]) { $1 }
        server.standardInput = FileHandle.nullDevice
        // What it says as it starts goes in a log, to be quoted if it doesn't.
        let output = try? FileHandle(forWritingTo: log)
        server.standardOutput = output ?? FileHandle.nullDevice
        server.standardError = output ?? FileHandle.nullDevice
        try server.run()
        process = server
        try? String(server.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        let chat = LocalChat(baseUrl: "http://127.0.0.1:\(port)/v1", model: model.id, key: key, sampling: (model.thinking, model.direct))
        // Loading takes a few seconds, longer the first time after a restart.
        for _ in 0..<480 {
            guard server.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8))?.trimmed.suffix(400) ?? ""
                process = nil
                throw OatcakeError("The language model couldn’t start. \(tail.isEmpty ? "" : "llama.cpp said: …\(tail)")")
            }
            // Another program that took the port in the moment after freePort() gave it up answers
            // too, even before llama.cpp has tried for it. So the answer counts only once llama.cpp
            // has said in its log that it's listening there, which it does once it holds the port.
            // One that couldn't take it stops instead, and the guard above says so.
            if await chat.isReady(), server.isRunning,
               Self.saysListening((try? String(contentsOf: log, encoding: .utf8)) ?? "", port: port) {
                running = (model.id, context, chat)
                return chat
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                stop()
                throw error
            }
        }
        stop()
        throw OatcakeError("The language model took too long to start.")
    }

    /// What llama.cpp's server is started with, for one model and window.
    static func arguments(_ model: LocalModel, file: URL, port: Int, context: Int) -> [String] {
        var arguments = ["-m", file.path, "--host", "127.0.0.1", "--port", String(port),
                         "-c", String(context), "-ngl", "99", "-fa", "on", "--no-context-shift", "--no-webui", "--jinja", "-np", "1",
                         // A long call on a slow Mac can take longer to write up than llama.cpp's ten minutes.
                         "--timeout", "3600",
                         // No copies of earlier prompts in memory. llama.cpp keeps up to 8 GB of them, which
                         // the memory a model is given room for doesn't count: 2.7 to 7.2 GB more once a second
                         // hour-long call is written up. Oatcake seldom goes back to an earlier prompt (a
                         // summary written again after something else reads its transcript again). The
                         // prompt the server holds is still reused, so the to-dos after a summary don't
                         // read the transcript again.
                         "--cache-ram", "0"]
        if model.stretch(context) > 1 {
            arguments += ["--rope-scaling", "yarn", "--rope-scale", String(model.stretch(context)), "--yarn-orig-ctx", String(model.nativeContext)]
        }
        return arguments
    }

    /// Stops the server now, whatever it's doing: at quit, and when its model is removed.
    public func stop() {
        process?.terminate()
        process = nil
        running = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Frees the model's memory when nothing has used it for a while.
    public func stopIfIdle(for seconds: TimeInterval) {
        if process != nil, leases == 0, !changing, Date().timeIntervalSince(lastUsed) > seconds { stop() }
    }

    public var isRunning: Bool { process?.isRunning == true }

    /// Stops the server by the note of its process ID: at quit (nothing can be awaited then), and
    /// for one left behind by a copy of Oatcake that didn't get to stop it.
    public nonisolated static func stopLeftover(in data: URL = Paths.data) {
        let file = pidFile(in: data)
        if let pid = runningPid(in: file, program: "llama-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: file)
    }

    /**
     * Checks that Oatcake.app's own signature still covers everything in it. llama.cpp's server may
     * load any library beside it (Resources/Llama.entitlements), so it isn't started when a file in
     * the app has been changed, added or taken away. The app on the disk also has to be the copy
     * that's running: one changed and then signed again (by anyone, ad hoc) is whole, but isn't
     * Oatcake. It's checked before every start; a file changed in the moment between the check and
     * the start isn't caught.
     */
    static func checkSealed(_ app: URL) throws {
        var me: SecCode?, code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCheckValidity(me, [], nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess else {
            throw OatcakeError("Oatcake.app isn’t as it was built (something in it has been changed, added or taken away), so the language model wasn’t started. Quit Oatcake and open it again; if this comes back, install Oatcake again.")
        }
    }

    /**
     * Whether llama.cpp's log says it's listening on this Mac's own address at `port`. At the pinned
     * build (Scripts/bundle.sh) that's "srv  server_on_li: listening on http://127.0.0.1:54321",
     * written by server_on_listening in tools/server/server.cpp once the port is bound and the model
     * loaded. A new build of llama.cpp needs this checking again: if the words change, the model
     * never counts as started.
     */
    static func saysListening(_ log: String, port: Int) -> Bool {
        log.range(of: #"listening on http://127\.0\.0\.1:\#(port)(?!\d)"#, options: .regularExpression) != nil
    }

    /// A port nobody is listening on, from the system.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OatcakeError("Couldn’t find a free port for the language model.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard bound == 0, named == 0 else { throw OatcakeError("Couldn’t find a free port for the language model.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
