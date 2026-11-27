import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ConfigTests {
    @Test func jargon() {
        var config = Config.defaults()
        #expect(config.jargonLine.isEmpty)
        config.jargon = ["Automattic", " ", "WooCommerce"]
        #expect(config.jargonLine.hasSuffix("Automattic, WooCommerce."))
        // Typed in Settings as one line, separated by commas or new lines.
        #expect(commaList(" Focus time,Out of office ,\n, Task\n") == ["Focus time", "Out of office", "Task"] && commaList(" , ").isEmpty)
    }

    /// The templates offered for a meeting: those with a name and instructions.
    @Test func summaryTemplateChoices() {
        var config = Config.defaults()
        config.summaryTemplates = [SummaryTemplate(name: "1:1", instructions: "Wins."), SummaryTemplate(name: " ", instructions: "Unnamed."),
                                   SummaryTemplate(name: "Empty", instructions: "  ")]
        #expect(config.summaryTemplateChoices.map(\.name) == ["1:1"])
    }

    /// A server of your own's context, as you've told Oatcake: none to start with (Qwen3's native
    /// window is planned for, as before), saved with the rest, read on its own, and never planned for
    /// below the minimum. Oatcake's own models are sized as before.
    @Test func ownServerContext() throws {
        var llm = LlmConfig(model: LlmConfig.ownServer)
        #expect(llm.own.context == nil && llm.own.contextBudget == 32_768 && largestContext(llm) == 32_768)
        llm.own.context = 131_072
        let saved = try JSONDecoder().decode(LlmConfig.self, from: JSONEncoder().encode(llm))
        #expect(saved.own.context == 131_072 && largestContext(saved) == 131_072)
        llm.own.context = 4_096
        #expect(largestContext(llm) == LlmConfig.Own.minimumContext)
        let unreadable = try JSONDecoder().decode(LlmConfig.self, from: Data(#"{"model":"own","own":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1","context":"big"}}"#.utf8))
        #expect(unreadable.own.context == nil && unreadable.own.model == "llama3.1" && largestContext(unreadable) == 32_768)
        let qwen = LocalModels.all[0]
        #expect(largestContext(with(llm) { $0.model = qwen.id }) == LocalModels.maxContext(qwen))
    }

    /// Settings from when the choice was a provider: a model server of your own carries over, and
    /// anything that sent transcripts elsewhere becomes the model Oatcake runs itself.
    @Test func olderModelSettings() throws {
        func read(_ json: String) throws -> LlmConfig { try JSONDecoder().decode(LlmConfig.self, from: Data(json.utf8)) }
        let own = LocalModels.recommended().id
        #expect(try read(#"{"provider":"claude-code","claudeCode":{"model":"opus","effort":"high"}}"#) == LlmConfig(model: own))
        #expect(try read(#"{"provider":"anthropic","anthropic":{"model":"claude-opus-4-5"}}"#) == LlmConfig(model: own))
        #expect(try read(#"{"provider":"openai-compatible","openai":{"baseUrl":"https://api.openai.com/v1","model":"gpt"}}"#).model == own)
        for json in [#"{"provider":"local","local":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1","effort":"low"}}"#,
                     #"{"provider":"openai-compatible","openai":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1"}}"#] {
            let llm = try read(json)
            #expect(llm.model == LlmConfig.ownServer && llm.own.baseUrl == "http://localhost:11434/v1" && llm.own.model == "llama3.1")
            // Saved again, it's in today's shape, which reads back the same.
            let saved = try JSONEncoder().encode(llm)
            #expect(!String(decoding: saved, as: UTF8.self).contains("provider"))
            #expect(try JSONDecoder().decode(LlmConfig.self, from: saved) == llm)
        }
        // Today's shape: one of Oatcake's models by name. A name it doesn't know is the recommended one.
        #expect(try read(#"{"model":"qwen3-4b"}"#).model == "qwen3-4b")
        #expect(try read(#"{"model":"gpt-9"}"#).model == own)
        // Reasoning starts where each task did best, and a switch that's been set is kept.
        let start = try read(#"{"model":"qwen3-8b"}"#).reasoning
        #expect(start.summary && !start.todos && start.names && start.ask)
        let set = try read(#"{"model":"qwen3-8b","reasoning":{"todos":true,"ask":false}}"#)
        #expect(set.reasoning.summary && set.reasoning.todos && set.reasoning.names && !set.reasoning.ask)
        #expect(try JSONDecoder().decode(LlmConfig.self, from: JSONEncoder().encode(set)) == set)
        // Each of Oatcake's models starts with its own switches; a server of your own with Qwen3's.
        let off = LlmConfig.Reasoning(summary: false, todos: false, names: false, ask: false, sharing: false)
        #expect(try read(#"{"model":"qwen3.6-35b-a3b"}"#).reasoning == off && LlmConfig(model: "qwen3.5-4b").reasoning == off)
        #expect(LlmConfig(model: "qwen3-4b").reasoning == LlmConfig.Reasoning() && LlmConfig(model: LlmConfig.ownServer).reasoning == LlmConfig.Reasoning())
        #expect(try read(#"{"model":"qwen3.6-35b-a3b","reasoning":{"summary":true}}"#).reasoning.summary)
        // What Settings says changed when a model brings its own switches.
        #expect(LlmConfig.Reasoning().change(to: off) == "off for summaries, drafts for sharing, name suggestions and Ask")
        #expect(off.change(to: LlmConfig.Reasoning()) == "on for summaries, drafts for sharing, name suggestions and Ask")
        #expect(set.reasoning.change(to: off) == "off for summaries, to-dos, drafts for sharing and name suggestions")
        #expect(with(off) { $0.todos = true }.change(to: with(off) { $0.ask = true }) == "on for Ask, and off for to-dos")
        #expect(off.change(to: off) == nil)
        // The summary's instructions are Oatcake's own until you write yours.
        var config = Config.defaults()
        #expect(config.summaryTask == defaultSummaryInstructions)
        config.summaryInstructions = "  Three bullet points, in French.\n"
        #expect(config.summaryTask == "Three bullet points, in French.")
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(config).utf8)).summaryInstructions == config.summaryInstructions)
        // The same for what counts as a to-do. The shape they come back in isn't yours to change.
        #expect(config.todosTask == defaultTodoInstructions + "\n" + todosFormat)
        config.todoInstructions = "  Only my own action items.\n"
        #expect(config.todosTask == "Only my own action items.\n" + todosFormat)
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(config).utf8)).todoInstructions == config.todoInstructions)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"myName":"John"}"#.utf8)).todoInstructions == "")
    }

    @Test func backgroundPreference() throws {
        #expect(Config.defaults().runInBackground)
        let existing = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(existing.runInBackground)
        let disabled = with(existing) { $0.runInBackground = false }
        let saved = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(disabled))
        #expect(!saved.runInBackground)
    }

    @Test func olderConfig() throws {
        let old = #"{"myName":"John","outputDir":"/tmp/m","asrModel":"parakeet-unified-en","keepAudio":false,"mic":null,"callReminders":false,"updateCheck":true}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.callNotice && config.autoStop && config.liveTranscript && config.liveVoices && config.menuBarNextCall && config.jargon.isEmpty)
        #expect(try !JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.liveVoices = false }).utf8)).liveVoices)
        #expect(!config.callReminders && config.myName == "John")
        let again = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.autoStop = false; $0.jargon = ["Jetpack"] }).utf8))
        #expect(!again.autoStop && again.jargon == ["Jetpack"])
        // Calls wait for who's who unless you've chosen otherwise, and the choice reads back.
        #expect(config.afterCall == .review)
        let saving = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.afterCall = .saveTranscript }).utf8))
        #expect(saving.afterCall == .saveTranscript)
        let unknown = try JSONDecoder().decode(Config.self, from: Data(#"{"afterCall":"somethingNew"}"#.utf8))
        #expect(unknown.afterCall == .review)
        // Summary templates: none to begin with, and they read back.
        #expect(config.summaryTemplates.isEmpty)
        let templates = [SummaryTemplate(name: "1:1 I lead", instructions: "Wins and blockers."), SummaryTemplate(name: "Team", instructions: "Decisions.")]
        let withTemplates = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.summaryTemplates = templates }).utf8))
        #expect(withTemplates.summaryTemplates == templates)
        #expect(withTemplates.summaryTask(template: " Team ") == "Decisions." && withTemplates.summaryTask(template: "team") == withTemplates.summaryTask)
        #expect(withTemplates.summaryTask(template: nil) == defaultSummaryInstructions)
        // To-dos are collected unless you've turned them off, and that reads back.
        #expect(config.todosEnabled)
        let noTodos = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.todosEnabled = false }).utf8))
        #expect(!noTodos.todosEnabled)
    }

    /// Every setting is saved and read back: a Config with each one changed from what Oatcake comes
    /// with, encoded and decoded, comes back the same. A setting left out of `encode` would never be
    /// saved, and nothing else would say so. Each property is checked to have been changed here, so
    /// a new setting fails this test until it's added to it.
    @Test func everySettingIsSavedAndReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-every-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var changed = Config.defaults()
        changed.myName = "Jane Doe"
        changed.outputDir = "/tmp/Somewhere else"
        changed.asrModel = "sensevoice"
        changed.llm = with(LlmConfig(model: LlmConfig.ownServer)) {
            $0.own.baseUrl = "http://localhost:11434/v1"
            $0.own.model = "llama3.1"
            $0.own.context = 65_536
            $0.own.reasoningControl = .ollama
            $0.reasoning.todos = true
            $0.reasoning.sharing = false
        }
        changed.keepAudio = true
        changed.mic = MicChoice(uid: "usb-1", name: "Desk microphone")
        changed.callReminders = false
        changed.updateCheck = false
        changed.runInBackground = false
        changed.callNotice = false
        changed.autoStop = false
        changed.liveTranscript = false
        changed.liveVoices = false
        changed.afterCall = .saveTranscript
        changed.jargon = ["Oatcake"]
        changed.menuBarNextCall = false
        changed.summaryInstructions = "Three bullet points."
        changed.todoInstructions = "Only my own action items."
        changed.summaryTemplates = [SummaryTemplate(name: "1:1", instructions: "Wins and blockers.")]
        changed.sharingInstructions = "Write it in French."
        changed.ignoredEvents = ["Lunch"]
        changed.todosEnabled = false
        changed.mcpEnabled = true
        changed.mcpApprovedRoot = try MCPServer.RootIdentity.approve(dir)
        changed.ignoredCalendarEvents = [IgnoredEvent(id: "e", series: true, title: "Weekly sync", start: nil, end: nil)]
        changed.reminderMinutes = [10, 1]

        let defaults = Mirror(reflecting: Config.defaults()).children.map { "\($0.value)" }
        for (setting, value) in zip(Mirror(reflecting: changed).children, defaults) {
            #expect("\(setting.value)" != value, "\(setting.label ?? "A setting") isn't changed from its default here: add it to this test")
        }
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(changed).utf8)) == changed)
        // Reminder times as Settings offers them: one at least, each from a minute to an hour before, each once.
        let reminders = { (json: String) in try JSONDecoder().decode(Config.self, from: Data(json.utf8)).reminderMinutes }
        #expect(try reminders(#"{"reminderMinutes":[]}"#) == [5] && reminders(#"{"reminderMinutes":"soon"}"#) == [5])
        #expect(try reminders(#"{"reminderMinutes":[0,90,5,-3,5,60]}"#) == [1, 60, 5])
    }

    /// Settings that can't be read aren't quietly replaced by the first change made after them.
    @Test func settingsThatCannotBeRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json"), kept = dir.appendingPathComponent("config.unreadable.json")
        // None yet: the ones Oatcake comes with are written, and there's nothing to say.
        #expect(Config.loadWithProblem(file: file).problem == nil && FileManager.default.fileExists(atPath: file.path))
        try with(Config.defaults()) { $0.myName = "John"; $0.outputDir = "/tmp/m" }.save(to: file)
        let read = Config.loadWithProblem(file: file)
        #expect(read.config.myName == "John" && read.problem == nil && !FileManager.default.fileExists(atPath: kept.path))
        // A hand edit that went wrong.
        try #"{"myName": "John", "outputDir": }"#.write(to: file, atomically: true, encoding: .utf8)
        let broken = Config.loadWithProblem(file: file)
        #expect(broken.config.outputDir == Config.defaults().outputDir && broken.problem?.contains("config.unreadable.json") == true)
        #expect(readText(kept) == #"{"myName": "John", "outputDir": }"#)
    }

    /// The speech-to-text setting: each choice, the Electron version's name for one, and a name this
    /// version doesn't know (from a newer one), which is the default.
    @Test func speechModels() {
        #expect(SpeechModels.asr.map(\.key) == ["parakeet-en", "bark-en", "parakeet-multilingual", "sensevoice"])
        #expect(SpeechModels.asrChoice("bark-en").decoder == .parakeet(.bark3Clean))
        #expect(SpeechModels.asrChoice("sensevoice").decoder == .senseVoice)
        #expect(SpeechModels.asrChoice("parakeet-tdt-v3").key == "parakeet-multilingual")
        #expect(SpeechModels.asrChoice("whisper-large").key == SpeechModels.defaultAsr)
    }
}
