import Foundation

public enum Effort: String, Codable, CaseIterable, Sendable { case low, medium, high }

/// Who writes summaries: Claude, or a model on your own Mac or network. Nothing else.
public enum LlmProvider: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case anthropic
    /// A model on this Mac or your own network (Ollama, LM Studio…).
    case local

    /// Settings saved before 0.4 called the third choice "openai-compatible" and let it be any address.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let provider = LlmProvider(rawValue: raw == "openai-compatible" ? "local" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown provider \(raw)"))
        }
        self = provider
    }
}

/**
 * Which model writes summaries and suggests names. Each provider keeps its own settings, so
 * switching back and forth loses nothing. API keys are kept in the Keychain (see Secrets).
 */
public struct LlmConfig: Codable, Equatable, Sendable {
    // Each of these reads its settings one by one, like Config does: a key that's missing (a file from
    // another version, or one edited by hand) falls back to its default and leaves the others alone.
    public struct ClaudeCode: Codable, Equatable, Sendable {
        /// "" for Claude Code's default, or an alias such as "sonnet", "opus", "haiku".
        public var model = ""
        public var effort = Effort.medium
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
            effort = (try? c.decodeIfPresent(Effort.self, forKey: .effort)) ?? .medium
        }
    }
    public struct Anthropic: Codable, Equatable, Sendable {
        public var model = anthropicModels[0]
        public var effort = Effort.medium
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? anthropicModels[0]
            effort = (try? c.decodeIfPresent(Effort.self, forKey: .effort)) ?? .medium
        }
    }
    /// A model server on this Mac or your own network. `baseUrl` is its chat API's address, e.g.
    /// http://localhost:11434/v1 for Ollama.
    public struct Local: Codable, Equatable, Sendable {
        public var baseUrl = ""
        public var model = ""
        public var effort = Effort.medium
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseUrl = (try? c.decodeIfPresent(String.self, forKey: .baseUrl)) ?? ""
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
            effort = (try? c.decodeIfPresent(Effort.self, forKey: .effort)) ?? .medium
        }
    }

    public var provider: LlmProvider
    public var claudeCode = ClaudeCode()
    public var anthropic = Anthropic()
    public var local = Local()

    public init(provider: LlmProvider) { self.provider = provider }

    /// Settings saved before 0.4 kept the local server's address and model under "openai".
    private enum OlderKeys: String, CodingKey { case openai }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decodeIfPresent(LlmProvider.self, forKey: .provider)) ?? .claudeCode
        claudeCode = (try? c.decodeIfPresent(ClaudeCode.self, forKey: .claudeCode)) ?? ClaudeCode()
        anthropic = (try? c.decodeIfPresent(Anthropic.self, forKey: .anthropic)) ?? Anthropic()
        local = (try? c.decodeIfPresent(Local.self, forKey: .local))
            ?? (try? decoder.container(keyedBy: OlderKeys.self).decodeIfPresent(Local.self, forKey: .openai))
            ?? Local()
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

public let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

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

    public var meetingsRoot: URL { URL(fileURLWithPath: outputDir, isDirectory: true) }

    /// Worked out once: the defaults are read on nearly every load.
    private static let guessed: (myName: String, hasClaude: Bool) = (
        NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(),
        ShellEnvironment.which("claude") != nil
    )

    public static func defaults() -> Config {
        Config(
            myName: guessed.myName,
            outputDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Meetings").path,
            asrModel: SpeechModels.defaultAsr,
            // Claude Code reuses an existing Claude login; otherwise use the API.
            llm: LlmConfig(provider: guessed.hasClaude ? .claudeCode : .anthropic),
            keepAudio: false,
            mic: nil,
            callReminders: true,
            updateCheck: true
        )
    }

    init(myName: String, outputDir: String, asrModel: String, llm: LlmConfig, keepAudio: Bool, mic: MicChoice?, callReminders: Bool, updateCheck: Bool,
         callNotice: Bool = true, autoStop: Bool = true, liveTranscript: Bool = true, jargon: [String] = [], menuBarNextCall: Bool = true) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case myName, outputDir, asrModel, llm, keepAudio, mic, callReminders, updateCheck, callNotice, autoStop, liveTranscript, jargon, menuBarNextCall
    }

    /// For the model: how to spell the names and terms you've listed, or "" when there are none.
    public var jargonLine: String {
        let terms = jargon.map(\.trimmed).filter { !$0.isEmpty }
        return terms.isEmpty ? "" : "Spell these names and terms exactly as written here whenever they come up (the transcript may have misheard them): \(terms.joined(separator: ", "))."
    }

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

/// Apps opened from Finder get a bare PATH. The login shell's is borrowed, so `claude` is found.
public enum ShellEnvironment {
    public static let path: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Markers, because interactive shells can print terminal escape codes before the value.
        if let out = try? runCapturing(shell, ["-ilc", #"printf "<<PATH>>%s<<PATH>>" "$PATH""#], timeout: 5),
           case let parts = out.components(separatedBy: "<<PATH>>"), parts.count >= 3, !parts[1].isEmpty {
            return parts[1]
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// The full path of a command on the login shell's PATH.
    public static func which(_ command: String) -> URL? {
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The environment for child processes: the login shell's PATH, and none of Oatcake's API keys
    /// (Claude Code always uses its own sign-in and billing, whichever provider is chosen). Oatcake's
    /// own analysis helper keeps them: a key from your shell is its fallback too.
    public static func childEnvironment(keepApiKeys: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        if !keepApiKeys {
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        // The calendar's private address is nobody else's business either way.
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
