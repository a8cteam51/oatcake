import Foundation

/**
 * Which model writes summaries, suggests names and answers questions. It's always on your own
 * hardware: one of the models Oatcake downloads and runs itself (LocalModels), or a server of your
 * own on this Mac or your network.
 */
public struct LlmConfig: Codable, Equatable, Sendable {
    /// What `model` is when the model is on a server of your own.
    public static let ownServer = "own"

    /**
     * The switch a server of your own takes for whether its model reasons before it replies. Servers
     * don't share one, so it's sent only once you've said which: then each task's Reasoning switch
     * goes with its requests. Ollama's OpenAI-compatible API takes `reasoning_effort` ("none" turns
     * reasoning off; any other level turns it on for a model that only has on and off); llama.cpp's
     * server takes `enable_thinking` for a model whose chat template reads it, as Qwen3's does.
     */
    public enum ReasoningControl: String, Codable, Sendable {
        case ollama
        case llamaCpp = "llama.cpp"
    }

    /// A model server of yours, such as Ollama or LM Studio: its chat API's address
    /// (http://localhost:11434/v1 for Ollama) and the model's name there.
    public struct Own: Codable, Equatable, Sendable {
        /// Which reasoning switch the server takes, if you've said. None: it decides for itself.
        public var reasoningControl: ReasoningControl?
        public var baseUrl = ""
        public var model = ""
        /// How many tokens the server is set to hold at once (Ollama's num_ctx, llama.cpp's -c), if
        /// you've said: Oatcake plans each request to fit. It doesn't change the server's own setting.
        public var context: Int?
        public init() {}
        // Read one by one, like Config: a key that's missing leaves the other alone.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reasoningControl = try? c.decodeIfPresent(ReasoningControl.self, forKey: .reasoningControl)
            baseUrl = (try? c.decodeIfPresent(String.self, forKey: .baseUrl)) ?? ""
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
            context = try? c.decodeIfPresent(Int.self, forKey: .context)
        }

        /// The window Oatcake plans for: yours (never less than `minimumContext`), or else Qwen3's native one.
        public var contextBudget: Int { context.map { max($0, Self.minimumContext) } ?? LocalModels.nativeContext }
        /// Room for a reply as long as Oatcake allows one (8,192 tokens) and some of the call beside it.
        public static let minimumContext = 16_384
    }

    /**
     * Whether the model thinks a task through before it replies, for each thing it's asked to do.
     * It's slower with it and not always better. Each of Oatcake's models comes with the switches
     * that suited it (LocalModel.reasoning). These are Qwen3's, measured on an hour-and-a-half
     * call, several runs each way: with it, summaries gave a decision to the right person far more
     * reliably, names were invented less often, and Ask kept to what was asked; without it, to-dos
     * kept what was decided, where with it they often lost the detail.
     */
    public struct Reasoning: Codable, Equatable, Sendable {
        public var summary = true
        public var todos = false
        public var names = true
        public var ask = true
        /// Drafts for sharing. Not measured: it starts as summaries do, which it's closest to.
        public var sharing = true
        public init() {}
        public init(summary: Bool, todos: Bool, names: Bool, ask: Bool, sharing: Bool) {
            self.summary = summary
            self.todos = todos
            self.names = names
            self.ask = ask
            self.sharing = sharing
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let start = Reasoning()
            summary = (try? c.decodeIfPresent(Bool.self, forKey: .summary)) ?? start.summary
            todos = (try? c.decodeIfPresent(Bool.self, forKey: .todos)) ?? start.todos
            names = (try? c.decodeIfPresent(Bool.self, forKey: .names)) ?? start.names
            ask = (try? c.decodeIfPresent(Bool.self, forKey: .ask)) ?? start.ask
            sharing = (try? c.decodeIfPresent(Bool.self, forKey: .sharing)) ?? start.sharing
        }

        /// What's different in `other`, as Settings says it: "off for summaries and Ask", or "on for
        /// to-dos, and off for name suggestions". Nil when nothing is.
        public func change(to other: Reasoning) -> String? {
            // In the order Settings › Summaries shows them.
            let tasks: [(String, KeyPath<Reasoning, Bool>)] = [("summaries", \.summary), ("to-dos", \.todos), ("drafts for sharing", \.sharing),
                                                               ("name suggestions", \.names), ("Ask", \.ask)]
            let changed = tasks.filter { self[keyPath: $0.1] != other[keyPath: $0.1] }
            let on = changed.filter { other[keyPath: $0.1] }.map(\.0), off = changed.filter { !other[keyPath: $0.1] }.map(\.0)
            func list(_ names: [String]) -> String { names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last! }
            let parts = [on.isEmpty ? nil : "on for " + list(on), off.isEmpty ? nil : "off for " + list(off)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", and ")
        }
    }

    /// One of LocalModels' ids ("qwen3.6-35b-a3b", "qwen3.5-4b"…), or "own".
    public var model: String
    public var own = Own()
    public var reasoning = Reasoning()

    /// The model that suits this Mac's memory, with its own reasoning switches.
    public init() { self.init(model: LocalModels.recommended().id) }

    /// One of Oatcake's models starts with the switches that suited it; a server of your own with Qwen3's.
    public init(model: String) {
        self.model = model
        reasoning = LocalModels.find(model)?.reasoning ?? Reasoning()
    }

    /// Earlier, the choice was a provider (Claude Code, the Anthropic API, or any OpenAI-compatible
    /// address) with its settings under its own key.
    private enum OlderKeys: String, CodingKey { case provider, local, openai }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        own = (try? c.decodeIfPresent(Own.self, forKey: .own)) ?? Own()
        if let saved = try? c.decodeIfPresent(String.self, forKey: .model), saved == Self.ownServer || LocalModels.find(saved) != nil {
            model = saved
        // Older settings: a local server that was set up carries over; Claude doesn't, and neither
        // does an address that isn't on your Mac or network.
        } else if let older = try? decoder.container(keyedBy: OlderKeys.self),
                  let provider = try? older.decodeIfPresent(String.self, forKey: .provider), provider == "local" || provider == "openai-compatible",
                  let server = ((try? older.decodeIfPresent(Own.self, forKey: .local)) ?? nil) ?? ((try? older.decodeIfPresent(Own.self, forKey: .openai)) ?? nil),
                  !server.baseUrl.trimmed.isEmpty, isLocalEndpoint(server.baseUrl) {
            own = server
            model = Self.ownServer
        } else {
            model = LocalModels.recommended().id
        }
        // Switches that have been saved are kept; until then, the model's own.
        reasoning = (try? c.decodeIfPresent(Reasoning.self, forKey: .reasoning)) ?? LocalModels.find(model)?.reasoning ?? Reasoning()
    }
}

/// What happens to a recording once it has been processed.
public enum AfterCall: String, Codable, CaseIterable, Sendable {
    /// It waits under Needs review until who's who has been checked and it's saved (as it always has).
    case review
    /// It's saved straight away, the voices Oatcake is sure it recognised under their names and the rest as
    /// "Voice 1", "Voice 2"… (they can be named later), then summarised.
    case saveWithSummary
    /// The same, with no summary or to-dos written.
    case saveTranscript
}

/// Summary instructions with a name of their own (Settings › Summaries), for the meetings that need
/// a different summary: a one-to-one you lead, say, or one with your own lead.
public struct SummaryTemplate: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var instructions: String
    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }
}

/// A list typed as one line in Settings (Jargon, Events that aren't calls): separated by commas or
/// new lines, each trimmed, blanks left out.
public func commaList(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { String($0).trimmed }.filter { !$0.isEmpty }
}

public struct Config: Codable, Equatable, Sendable {
    /// Your name: the microphone track is always you.
    public var myName: String
    /// The Meetings folder. Each meeting is a folder inside it (or inside any subfolder).
    public var outputDir: String
    /// Speech-to-text model, a key of SpeechModels.asr.
    public var asrModel: String
    public var llm: LlmConfig
    /// Keep the call's audio after it's saved: it goes into the meeting's folder as audio.m4a.
    public var keepAudio: Bool
    /// The microphone to record. nil follows the Mac's input (System Settings › Sound).
    public var mic: MicChoice?
    /// Notifications before each call (reminderMinutes), with a button to open it and start recording.
    public var callReminders: Bool
    /// Look for a new release 20 seconds after launch and once a day.
    public var updateCheck: Bool
    /// Keep checking for calls after the last window closes.
    public var runInBackground: Bool
    /// A notification offering to record when a calling app starts using the microphone.
    public var callNotice: Bool
    /// Stop recording once the calling app has let go of the microphone and the call audio has gone quiet.
    public var autoStop: Bool
    /// Transcribe during the call, for the live transcript beside your notes.
    public var liveTranscript: Bool
    /// Name the voices in the live transcript: people Oatcake knows by voice, and anyone you name on a
    /// line. Turned off, the live transcript doesn't load the voice models (memory and CPU saved).
    public var liveVoices: Bool
    /// Wait for who's who, or save the meeting as soon as it's processed (unchecked: it can be named later).
    public var afterCall: AfterCall
    /// Names, products and acronyms the summary model should spell as written here.
    public var jargon: [String]
    /// With a calendar connected, show the time until the next call in the menu bar.
    public var menuBarNextCall: Bool
    /// What the model is told when it writes a summary, when you've changed it. "" = Oatcake's own
    /// (defaultSummaryInstructions), so an improvement to those reaches everyone who hasn't.
    public var summaryInstructions: String
    /// What the model is told counts as a to-do, when you've changed it. "" = Oatcake's own (defaultTodoInstructions).
    public var todoInstructions: String
    /// Other summary instructions, by name, for a meeting to be summarised with instead (Regenerate
    /// summary). Meetings that haven't chosen one use summaryInstructions.
    public var summaryTemplates: [SummaryTemplate]
    /// What the model is told when it writes a draft for sharing, when you've changed it. "" = Oatcake's
    /// own (defaultSharingInstructions).
    public var sharingInstructions: String
    /// Calendar events whose titles start with one of these aren't offered as calls (ignoredEvent).
    public var ignoredEvents: [String]
    /// To-dos: collected from each call with its summary, and shown on the To-dos page and in each
    /// meeting. Off, none are collected or shown; todo.md files already saved are left as they are.
    public var todosEnabled: Bool
    /// Other apps may read the saved meetings over MCP (`Oatcake --mcp`, which reads this for every
    /// request), but only from the Meetings folder as it was when this was turned on.
    public var mcpEnabled = false
    public var mcpApprovedRoot: MCPServer.RootIdentity?
    /// Google Calendar's names for blocks that aren't calls.
    public static let defaultIgnoredEvents = ["Focus time", "Out of office", "Working location", "Task"]
    /// Events ignored one at a time from Upcoming, or a recurring one's whole series (isIgnored).
    public var ignoredCalendarEvents: [IgnoredEvent] = []
    /// How many minutes before each call its reminders come, one reminder for each (5 and 1, say).
    public var reminderMinutes = [5]

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
         runInBackground: Bool = true, callNotice: Bool = true, autoStop: Bool = true, liveTranscript: Bool = true, liveVoices: Bool = true, jargon: [String] = [], menuBarNextCall: Bool = true,
         summaryInstructions: String = "", todoInstructions: String = "", ignoredEvents: [String] = Config.defaultIgnoredEvents,
         afterCall: AfterCall = .review, summaryTemplates: [SummaryTemplate] = [], todosEnabled: Bool = true,
         sharingInstructions: String = "") {
        self.myName = myName
        self.outputDir = outputDir
        self.asrModel = asrModel
        self.llm = llm
        self.keepAudio = keepAudio
        self.mic = mic
        self.callReminders = callReminders
        self.updateCheck = updateCheck
        self.runInBackground = runInBackground
        self.callNotice = callNotice
        self.autoStop = autoStop
        self.liveTranscript = liveTranscript
        self.liveVoices = liveVoices
        self.jargon = jargon
        self.menuBarNextCall = menuBarNextCall
        self.summaryInstructions = summaryInstructions
        self.todoInstructions = todoInstructions
        self.summaryTemplates = summaryTemplates
        self.sharingInstructions = sharingInstructions
        self.ignoredEvents = ignoredEvents
        self.afterCall = afterCall
        self.todosEnabled = todosEnabled
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
        runInBackground = (try? c.decodeIfPresent(Bool.self, forKey: .runInBackground)) ?? base.runInBackground
        callNotice = (try? c.decodeIfPresent(Bool.self, forKey: .callNotice)) ?? base.callNotice
        autoStop = (try? c.decodeIfPresent(Bool.self, forKey: .autoStop)) ?? base.autoStop
        liveTranscript = (try? c.decodeIfPresent(Bool.self, forKey: .liveTranscript)) ?? base.liveTranscript
        liveVoices = (try? c.decodeIfPresent(Bool.self, forKey: .liveVoices)) ?? base.liveVoices
        jargon = (try? c.decodeIfPresent([String].self, forKey: .jargon)) ?? base.jargon
        menuBarNextCall = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarNextCall)) ?? base.menuBarNextCall
        summaryInstructions = (try? c.decodeIfPresent(String.self, forKey: .summaryInstructions)) ?? base.summaryInstructions
        todoInstructions = (try? c.decodeIfPresent(String.self, forKey: .todoInstructions)) ?? base.todoInstructions
        summaryTemplates = (try? c.decodeIfPresent([SummaryTemplate].self, forKey: .summaryTemplates)) ?? base.summaryTemplates
        sharingInstructions = (try? c.decodeIfPresent(String.self, forKey: .sharingInstructions)) ?? base.sharingInstructions
        ignoredEvents = (try? c.decodeIfPresent([String].self, forKey: .ignoredEvents)) ?? base.ignoredEvents
        ignoredCalendarEvents = (try? c.decodeIfPresent([IgnoredEvent].self, forKey: .ignoredCalendarEvents)) ?? base.ignoredCalendarEvents
        // As Settings offers them: an hour before at most, a minute at least, each once, and one at least.
        var seen = Set<Int>()
        let minutes = ((try? c.decodeIfPresent([Int].self, forKey: .reminderMinutes)) ?? []).map { min(60, max(1, $0)) }.filter { seen.insert($0).inserted }
        reminderMinutes = minutes.isEmpty ? base.reminderMinutes : minutes
        afterCall = (try? c.decodeIfPresent(AfterCall.self, forKey: .afterCall)) ?? base.afterCall
        todosEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .todosEnabled)) ?? base.todosEnabled
        mcpEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .mcpEnabled)) ?? false
        mcpApprovedRoot = try? c.decodeIfPresent(MCPServer.RootIdentity.self, forKey: .mcpApprovedRoot)
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
        try c.encode(runInBackground, forKey: .runInBackground)
        try c.encode(callNotice, forKey: .callNotice)
        try c.encode(autoStop, forKey: .autoStop)
        try c.encode(liveTranscript, forKey: .liveTranscript)
        try c.encode(liveVoices, forKey: .liveVoices)
        try c.encode(jargon, forKey: .jargon)
        try c.encode(menuBarNextCall, forKey: .menuBarNextCall)
        try c.encode(summaryInstructions, forKey: .summaryInstructions)
        try c.encode(todoInstructions, forKey: .todoInstructions)
        try c.encode(summaryTemplates, forKey: .summaryTemplates)
        try c.encode(sharingInstructions, forKey: .sharingInstructions)
        try c.encode(ignoredEvents, forKey: .ignoredEvents)
        try c.encode(ignoredCalendarEvents, forKey: .ignoredCalendarEvents)
        try c.encode(reminderMinutes, forKey: .reminderMinutes)
        try c.encode(afterCall, forKey: .afterCall)
        try c.encode(todosEnabled, forKey: .todosEnabled)
        try c.encode(mcpEnabled, forKey: .mcpEnabled)
        try c.encodeIfPresent(mcpApprovedRoot, forKey: .mcpApprovedRoot)
    }

    private enum CodingKeys: String, CodingKey {
        case mcpEnabled, mcpApprovedRoot
        case myName, outputDir, asrModel, llm, keepAudio, mic, callReminders, updateCheck, runInBackground, callNotice, autoStop, liveTranscript, liveVoices, jargon, menuBarNextCall, summaryInstructions, todoInstructions, summaryTemplates, sharingInstructions, ignoredEvents, ignoredCalendarEvents, afterCall, todosEnabled, reminderMinutes
    }

    /// For the model: how to spell the names and terms you've listed, or "" when there are none.
    public var jargonLine: String {
        let terms = jargon.map(\.trimmed).filter { !$0.isEmpty }
        return terms.isEmpty ? "" : "Spell these names and terms exactly as written here whenever they come up (the transcript may have misheard them): \(terms.joined(separator: ", "))."
    }

    /// What the model is told when it writes a summary: yours, or Oatcake's own.
    public var summaryTask: String { summaryInstructions.trimmed.isEmpty ? defaultSummaryInstructions : summaryInstructions.trimmed }

    /// The template of that name, if there still is one (and it has instructions). Meetings keep
    /// their template by name, so a template given a deleted one's name again takes its meetings back.
    public func summaryTemplate(named name: String?) -> SummaryTemplate? {
        guard let name = name?.trimmed, !name.isEmpty else { return nil }
        return summaryTemplates.first { $0.name.trimmed == name && !$0.instructions.trimmed.isEmpty }
    }

    /// The templates a meeting can be summarised with (New recording, Regenerate): named, and with instructions.
    public var summaryTemplateChoices: [SummaryTemplate] { summaryTemplates.filter { summaryTemplate(named: $0.name) != nil } }

    /// What the model is told when it writes a summary with a template (by name): that template's
    /// instructions, or, with none or one that has gone since, the summary instructions.
    public func summaryTask(template name: String?) -> String { summaryTemplate(named: name)?.instructions.trimmed ?? summaryTask }

    /// What the model is told when it collects to-dos: which things count (yours, or Oatcake's own),
    /// then the shape to give them in, which stays Oatcake's.
    public var todosTask: String { (todoInstructions.trimmed.isEmpty ? defaultTodoInstructions : todoInstructions.trimmed) + "\n" + todosFormat }

    /// What the model is told when it writes a draft for sharing: yours, or Oatcake's own.
    public var sharingTask: String { sharingInstructions.trimmed.isEmpty ? defaultSharingInstructions : sharingInstructions.trimmed }

    public static func load() -> Config { loadWithProblem().config }

    /**
     * The settings, and what went wrong when the file is there and can't be read (a hand edit, a sync
     * conflict). Oatcake then starts on its defaults, and the first change to a setting would save
     * over the file: so it's kept beside itself as config.unreadable.json, and the problem is said.
     */
    public static func loadWithProblem(file: URL = Paths.config) -> (config: Config, problem: String?) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Config.self, from: data) { return (config, nil) }
        let base = defaults()
        guard FileManager.default.exists(file) else {
            try? base.save(to: file)
            return (base, nil)
        }
        let kept = keepUnreadable(file)
        return (base, "Oatcake couldn’t read its settings (\(file.lastPathComponent)), so it has started with the ones it comes with. The file is kept beside it as \(kept.lastPathComponent), and your Meetings folder may need choosing again in Settings › Storage.")
    }

    public func save(to file: URL = Paths.config) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(self) + "\n")
    }
}
