import Foundation

/**
 * Which model writes summaries, suggests names and answers questions. It's always on your own
 * hardware: one of the models Oatcake downloads and runs itself (LocalModels), or a server of your
 * own on this Mac or your network.
 */
public struct LlmConfig: Codable, Equatable, Sendable {
    /// What `model` is when the model is on a server of your own.
    public static let ownServer = "own"

    /// A model server of yours, such as Ollama or LM Studio: its chat API's address
    /// (http://localhost:11434/v1 for Ollama) and the model's name there.
    public struct Own: Codable, Equatable, Sendable {
        public var baseUrl = ""
        public var model = ""
        public init() {}
        // Read one by one, like Config: a key that's missing leaves the other alone.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseUrl = (try? c.decodeIfPresent(String.self, forKey: .baseUrl)) ?? ""
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        }
    }

    /**
     * Whether the model thinks a task through before it replies, for each thing it's asked to do.
     * It's slower with it and not always better. Each starts where it did best when measured on
     * an hour-and-a-half call, several runs each way: with it, summaries gave a decision to the
     * right person far more reliably, names were invented less often, and Ask kept to what was
     * asked; without it, to-dos kept what was decided, where with it they often lost the detail.
     */
    public struct Reasoning: Codable, Equatable, Sendable {
        public var summary = true
        public var todos = false
        public var names = true
        public var ask = true
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let start = Reasoning()
            summary = (try? c.decodeIfPresent(Bool.self, forKey: .summary)) ?? start.summary
            todos = (try? c.decodeIfPresent(Bool.self, forKey: .todos)) ?? start.todos
            names = (try? c.decodeIfPresent(Bool.self, forKey: .names)) ?? start.names
            ask = (try? c.decodeIfPresent(Bool.self, forKey: .ask)) ?? start.ask
        }
    }

    /// One of LocalModels' ids ("qwen3-8b", "qwen3-4b"), or "own".
    public var model: String
    public var own = Own()
    public var reasoning = Reasoning()

    /// The model that suits this Mac's memory.
    public init() { model = LocalModels.recommended().id }

    public init(model: String) { self.model = model }

    /// Earlier, the choice was a provider (Claude Code, the Anthropic API, or any OpenAI-compatible
    /// address) with its settings under its own key.
    private enum OlderKeys: String, CodingKey { case provider, local, openai }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        own = (try? c.decodeIfPresent(Own.self, forKey: .own)) ?? Own()
        reasoning = (try? c.decodeIfPresent(Reasoning.self, forKey: .reasoning)) ?? Reasoning()
        if let saved = try? c.decodeIfPresent(String.self, forKey: .model), saved == Self.ownServer || LocalModels.find(saved) != nil {
            model = saved
            return
        }
        // Older settings: a local server that was set up carries over; Claude doesn't, and neither
        // does an address that isn't on your Mac or network.
        model = LocalModels.recommended().id
        guard let older = try? decoder.container(keyedBy: OlderKeys.self),
              let provider = try? older.decodeIfPresent(String.self, forKey: .provider), provider == "local" || provider == "openai-compatible" else { return }
        let server = ((try? older.decodeIfPresent(Own.self, forKey: .local)) ?? nil) ?? ((try? older.decodeIfPresent(Own.self, forKey: .openai)) ?? nil)
        if let server, !server.baseUrl.trimmed.isEmpty, isLocalEndpoint(server.baseUrl) {
            own = server
            model = Self.ownServer
        }
    }
}

/**
 * Whether a model server's address is on this Mac or your own network: localhost, a name with no
 * dots or ending in .local, or a private or link-local IP address. Oatcake sends transcripts to a
 * local model only at an address like that, so one can't be pointed at somebody else's service.
 */
public func isLocalEndpoint(_ address: String) -> Bool {
    guard let url = URL(string: address.trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
    if host.contains(":") {
        // IPv6: this Mac, link-local, or a unique local address.
        return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, let n = Optional(parts.compactMap { UInt8($0) }), n.count == 4 {
        return n[0] == 127 || n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168) || (n[0] == 169 && n[1] == 254)
    }
    // A name: this Mac, a machine named on your network, or a Bonjour name.
    return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".")
}

public struct MicChoice: Codable, Equatable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// Your name: the microphone track is always you.
    public var myName: String
    /// The Meetings folder. Each meeting is a folder inside it (or inside any subfolder).
    public var outputDir: String
    /// Speech-to-text model, a key of SpeechModels.asr.
    public var asrModel: String
    public var llm: LlmConfig
    /// Keep the raw audio after a call is saved (needed to re-run with another model).
    public var keepAudio: Bool
    /// The microphone to record. nil follows the Mac's input (System Settings › Sound).
    public var mic: MicChoice?
    /// A notification 5 minutes before each call, with a button to open it and start recording.
    public var callReminders: Bool
    /// Look for a new release 20 seconds after launch and once a day.
    public var updateCheck: Bool
    /// A notification offering to record when a calling app starts using the microphone.
    public var callNotice: Bool
    /// Stop recording once the calling app has let go of the microphone and the call audio has gone quiet.
    public var autoStop: Bool
    /// Transcribe during the call, for the live transcript beside your notes.
    public var liveTranscript: Bool
    /// Names, products and acronyms the summary model should spell as written here.
    public var jargon: [String]
    /// With a calendar connected, show the time until the next call in the menu bar.
    public var menuBarNextCall: Bool
    /// What the model is told when it writes a summary, when you've changed it. "" = Oatcake's own
    /// (defaultSummaryInstructions), so an improvement to those reaches everyone who hasn't.
    public var summaryInstructions: String

    public var meetingsRoot: URL { URL(fileURLWithPath: outputDir, isDirectory: true) }

    /// Worked out once: the defaults are read on nearly every load.
    private static let guessedName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()

    public static func defaults() -> Config {
        Config(
            myName: guessedName,
            outputDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Meetings").path,
            asrModel: SpeechModels.defaultAsr,
            llm: LlmConfig(),
            keepAudio: false,
            mic: nil,
            callReminders: true,
            updateCheck: true
        )
    }

    init(myName: String, outputDir: String, asrModel: String, llm: LlmConfig, keepAudio: Bool, mic: MicChoice?, callReminders: Bool, updateCheck: Bool,
         callNotice: Bool = true, autoStop: Bool = true, liveTranscript: Bool = true, jargon: [String] = [], menuBarNextCall: Bool = true,
         summaryInstructions: String = "") {
        self.myName = myName
        self.outputDir = outputDir
        self.asrModel = asrModel
        self.llm = llm
        self.keepAudio = keepAudio
        self.mic = mic
        self.callReminders = callReminders
        self.updateCheck = updateCheck
        self.callNotice = callNotice
        self.autoStop = autoStop
        self.liveTranscript = liveTranscript
        self.jargon = jargon
        self.menuBarNextCall = menuBarNextCall
        self.summaryInstructions = summaryInstructions
    }

    /// Missing or unreadable settings fall back to the defaults one by one.
    public init(from decoder: Decoder) throws {
        let base = Config.defaults()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        myName = (try? c.decodeIfPresent(String.self, forKey: .myName)) ?? base.myName
        outputDir = (try? c.decodeIfPresent(String.self, forKey: .outputDir)) ?? base.outputDir
        asrModel = (try? c.decodeIfPresent(String.self, forKey: .asrModel)) ?? base.asrModel
        llm = (try? c.decodeIfPresent(LlmConfig.self, forKey: .llm)) ?? base.llm
        keepAudio = (try? c.decodeIfPresent(Bool.self, forKey: .keepAudio)) ?? base.keepAudio
        mic = try? c.decodeIfPresent(MicChoice.self, forKey: .mic)
        callReminders = (try? c.decodeIfPresent(Bool.self, forKey: .callReminders)) ?? base.callReminders
        updateCheck = (try? c.decodeIfPresent(Bool.self, forKey: .updateCheck)) ?? base.updateCheck
        callNotice = (try? c.decodeIfPresent(Bool.self, forKey: .callNotice)) ?? base.callNotice
        autoStop = (try? c.decodeIfPresent(Bool.self, forKey: .autoStop)) ?? base.autoStop
        liveTranscript = (try? c.decodeIfPresent(Bool.self, forKey: .liveTranscript)) ?? base.liveTranscript
        jargon = (try? c.decodeIfPresent([String].self, forKey: .jargon)) ?? base.jargon
        menuBarNextCall = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarNextCall)) ?? base.menuBarNextCall
        summaryInstructions = (try? c.decodeIfPresent(String.self, forKey: .summaryInstructions)) ?? base.summaryInstructions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(myName, forKey: .myName)
        try c.encode(outputDir, forKey: .outputDir)
        try c.encode(asrModel, forKey: .asrModel)
        try c.encode(llm, forKey: .llm)
        try c.encode(keepAudio, forKey: .keepAudio)
        // null, as the Electron version wrote it, rather than leaving the key out.
        if let mic { try c.encode(mic, forKey: .mic) } else { try c.encodeNil(forKey: .mic) }
        try c.encode(callReminders, forKey: .callReminders)
        try c.encode(updateCheck, forKey: .updateCheck)
        try c.encode(callNotice, forKey: .callNotice)
        try c.encode(autoStop, forKey: .autoStop)
        try c.encode(liveTranscript, forKey: .liveTranscript)
        try c.encode(jargon, forKey: .jargon)
        try c.encode(menuBarNextCall, forKey: .menuBarNextCall)
        try c.encode(summaryInstructions, forKey: .summaryInstructions)
    }

    private enum CodingKeys: String, CodingKey {
        case myName, outputDir, asrModel, llm, keepAudio, mic, callReminders, updateCheck, callNotice, autoStop, liveTranscript, jargon, menuBarNextCall, summaryInstructions
    }

    /// For the model: how to spell the names and terms you've listed, or "" when there are none.
    public var jargonLine: String {
        let terms = jargon.map(\.trimmed).filter { !$0.isEmpty }
        return terms.isEmpty ? "" : "Spell these names and terms exactly as written here whenever they come up (the transcript may have misheard them): \(terms.joined(separator: ", "))."
    }

    /// What the model is told when it writes a summary: yours, or Oatcake's own.
    public var summaryTask: String { summaryInstructions.trimmed.isEmpty ? defaultSummaryInstructions : summaryInstructions.trimmed }

    public static func load() -> Config {
        try? FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: Paths.config), let config = try? JSONDecoder().decode(Config.self, from: data) else {
            let base = defaults()
            if !FileManager.default.exists(Paths.config) { try? base.save() }
            return base
        }
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        try writeAtomic(Paths.config, try encodeJSON(self) + "\n")
    }
}

/// What Oatcake's own helper processes are started with: this process's environment, without the
/// calendar's private address, which is none of their business.
public enum ShellEnvironment {
    public static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OATCAKE_CALENDAR_URL")
        return env
    }
}

/// Runs a command and returns its standard output; throws with its error output when it fails.
@discardableResult
public func runCapturing(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil, environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    if let timeout {
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
    }
    // Both pipes are read before waiting (one on another thread), so a full pipe can't stall the process.
    var errData = Data()
    let errRead = DispatchGroup()
    errRead.enter()
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        errRead.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    errRead.wait()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errData, as: UTF8.self).trimmed
        throw OatcakeError(message.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus)" : message)
    }
    return String(decoding: outData, as: UTF8.self)
}
