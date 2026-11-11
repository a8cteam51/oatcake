// The language model that writes summaries, suggests names and answers questions runs on this Mac.
// It's Qwen3, in one of two sizes, run by llama.cpp's server: a small program inside Oatcake that is
// started on this Mac's own address (127.0.0.1) when there's something to write and stopped when
// there's been nothing for a while. The model's file is downloaded once, from a fixed revision on
// Hugging Face, and checked against its SHA-256 before it's used. Nothing is sent anywhere.

import CryptoKit
import Foundation

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

    public var downloadSize: String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// GB of memory with room for `context` tokens.
    func memory(context: Int) -> Double { baseMemory + memoryPerThousandTokens * Double(context) / 1000 }
}

public enum LocalModels {
    /// Qwen3 reads up to this many tokens as it was trained to. Beyond it the window is stretched
    /// (YaRN), which Qwen has checked up to 131,072 tokens and says to use only when a text needs it.
    public static let nativeContext = 32_768
    static let contexts = [8_192, 12_288, 16_384, 24_576, 32_768, 49_152, 65_536, 98_304, 131_072]

    public static let all: [LocalModel] = [
        LocalModel(id: "qwen3-8b", title: "Qwen3 8B",
                   detail: "The more careful of the two. On an hour-long call it kept nearly every decision, with its owner and date, in our tests. 5.0 GB to download; needs a Mac with 16 GB of memory or more.",
                   file: "Qwen3-8B-Q4_K_M.gguf",
                   url: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q4_K_M.gguf",
                   sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785", bytes: 5_027_783_488,
                   baseMemory: 5.0, memoryPerThousandTokens: 0.14),
        LocalModel(id: "qwen3-4b", title: "Qwen3 4B",
                   detail: "Half the size and about twice as fast, for Macs with 8 GB of memory. Fine on short calls; on long ones it loses detail, and missed decisions in our tests. 2.5 GB to download.",
                   file: "Qwen3-4B-Q4_K_M.gguf",
                   url: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf",
                   sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5", bytes: 2_497_280_256,
                   baseMemory: 2.6, memoryPerThousandTokens: 0.14),
    ]

    public static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    /// This Mac's memory in GB.
    public static var physicalMemory: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// The model to start with: the 8B where it fits, the 4B on a Mac with less memory.
    public static func recommended(memory: Double = physicalMemory) -> LocalModel { memory >= 15.5 ? all[0] : all[1] }

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

    /// How many times over a window stretches the positions the model was trained on (YaRN): 1 when
    /// it's within them. Only for a text that needs it, and no further than it needs (Qwen's own advice).
    public static func stretch(_ context: Int) -> Int { max(1, Int((Double(context) / Double(nativeContext)).rounded(.up))) }

    /// Whether a server running with one window can do a job that needs another: it has to be big
    /// enough, and stretched just as far as the job needs. A stretched window reads a shorter text
    /// a little worse, so a job that fits the model's own window never borrows one.
    public static func serves(running: Int, needed: Int) -> Bool { running >= needed && stretch(running) == stretch(needed) }

    /// A rough count of the tokens in a text: English runs at about four characters a token, other
    /// languages at fewer, so this errs on the high side.
    public static func tokens(in text: String) -> Int { text.utf8.count * 10 / 33 + 1 }

    public static var directory: URL { Paths.models.appendingPathComponent("llm", isDirectory: true) }
    public static func file(_ model: LocalModel) -> URL { directory.appendingPathComponent(model.file) }

    public static func isDownloaded(_ model: LocalModel) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: file(model).path))?[.size] as? Int64) == model.bytes
    }

    /// Removes a model's file (and a download of it that was left part-way).
    public static func remove(_ model: LocalModel) {
        try? FileManager.default.removeItem(at: file(model))
        try? FileManager.default.removeItem(at: file(model).appendingPathExtension("part"))
    }
}

public let modelNotDownloadedMessage = "The language model isn’t downloaded yet. Settings › Summaries shows how far it has got, and can start it again."

/// Downloads a model's file, carrying on from where an earlier attempt stopped, and checks it's the
/// file that was expected before putting it in place.
public final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModel
    private let part: URL
    private let progress: @Sendable (Double) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var reported = -1.0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    private init(_ model: LocalModel, part: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.part = part
        self.progress = progress
    }

    /// Downloads the model's file to where Oatcake keeps it (`file` is somewhere else only in tests).
    /// While it's on its way it's "<name>.part" beside that; it's only given its name once it's whole
    /// and its SHA-256 is the one expected.
    public static func fetch(_ model: LocalModel, to file: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let file = file ?? LocalModels.file(model)
        if ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) == model.bytes { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let download = ModelDownload(model, part: file.appendingPathExtension("part"), progress: progress)
        try await download.run()
        guard try sha256(of: download.part) == model.sha256 else {
            try? FileManager.default.removeItem(at: download.part)
            throw OatcakeError("The download of \(model.title) didn’t match its checksum, so it was thrown away. Try again.")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: download.part, to: file)
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
                continuation = c
                task.resume()
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
        continuation = nil
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

    /// llama.cpp's server: inside Oatcake.app, or in the folder OATCAKE_LLAMA_DIR names (for development).
    public static var binary: URL? {
        let folders = [ProcessInfo.processInfo.environment["OATCAKE_LLAMA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                       Bundle.main.resourceURL?.appendingPathComponent("llama", isDirectory: true)]
        return folders.compactMap { $0?.appendingPathComponent("llama-server") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var pidFile: URL { Paths.data.appendingPathComponent("model-server.pid") }
    static var log: URL { Paths.data.appendingPathComponent("model-server.log") }

    /// The model, loaded with room for at least `context` tokens. It's kept as it is until `release()`.
    func lease(_ model: LocalModel, context: Int) async throws -> LocalChat {
        while true {
            try Task.checkCancellation()
            if !changing {
                if let running, running.model == model.id, LocalModels.serves(running: running.context, needed: context), process?.isRunning == true {
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
        Self.stopLeftover()
        guard let binary = Self.binary else {
            throw OatcakeError("This copy of Oatcake was built without llama.cpp, which runs the language model. Build it with Scripts/bundle.sh.")
        }
        guard LocalModels.isDownloaded(model) else { throw OatcakeError(modelNotDownloadedMessage) }

        let port = try Self.freePort()
        let key = UUID().uuidString
        var arguments = ["-m", LocalModels.file(model).path, "--host", "127.0.0.1", "--port", String(port),
                         "-c", String(context), "-ngl", "99", "-fa", "on", "--no-context-shift", "--no-webui", "--jinja", "-np", "1",
                         // A long call on a slow Mac can take longer to write up than llama.cpp's ten minutes.
                         "--timeout", "3600"]
        if LocalModels.stretch(context) > 1 {
            arguments += ["--rope-scaling", "yarn", "--rope-scale", String(LocalModels.stretch(context)), "--yarn-orig-ctx", String(LocalModels.nativeContext)]
        }
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        let server = Process()
        server.executableURL = binary
        server.arguments = arguments
        // The key goes in its environment: a command line can be read by every account on the Mac.
        server.environment = ShellEnvironment.childEnvironment().merging(["LLAMA_API_KEY": key]) { $1 }
        server.standardInput = FileHandle.nullDevice
        // What it says as it starts goes in a log, to be quoted if it doesn't.
        let log = try? FileHandle(forWritingTo: Self.log)
        server.standardOutput = log ?? FileHandle.nullDevice
        server.standardError = log ?? FileHandle.nullDevice
        try server.run()
        process = server
        try? String(server.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)

        let chat = LocalChat(baseUrl: "http://127.0.0.1:\(port)/v1", model: model.id, key: key, qwen: true)
        // Loading takes a few seconds, longer the first time after a restart.
        for _ in 0..<480 {
            guard server.isRunning else {
                let tail = (try? String(contentsOf: Self.log, encoding: .utf8))?.trimmed.suffix(400) ?? ""
                process = nil
                throw OatcakeError("The language model couldn’t start. \(tail.isEmpty ? "" : "llama.cpp said: …\(tail)")")
            }
            if await chat.isReady() {
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

    /// Stops the server now, whatever it's doing: at quit, and when its model is removed.
    public func stop() {
        process?.terminate()
        process = nil
        running = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    /// Frees the model's memory when nothing has used it for a while.
    public func stopIfIdle(for seconds: TimeInterval) {
        if process != nil, leases == 0, !changing, Date().timeIntervalSince(lastUsed) > seconds { stop() }
    }

    public var isRunning: Bool { process?.isRunning == true }

    /// Stops the server by the note of its process ID: at quit (nothing can be awaited then), and
    /// for one left behind by a copy of Oatcake that didn't get to stop it.
    public nonisolated static func stopLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmed), pid > 1 else { return }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("/llama-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
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
