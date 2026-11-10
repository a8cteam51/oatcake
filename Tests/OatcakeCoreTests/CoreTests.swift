import Foundation
@testable import OatcakeCore
import Testing

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@Suite struct CalendarTests {
    /// The same feed and window through ical.js (the Electron version) gave calendar-expected.json.
    @Test func matchesIcalJs() throws {
        let text = try String(contentsOf: fixture("calendar.ics"), encoding: .utf8)
        let expected = try JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: fixture("calendar-expected.json")))
        let events = parseCalendar(text, from: parseISO("2026-10-20T00:00:00Z")!, to: parseISO("2026-11-20T00:00:00Z")!)
        #expect(events.count == expected.count)
        // Whole-day events are days in the local time zone, so only their shape is compared.
        for (got, want) in zip(events.filter { !$0.allDay }, expected.filter { !$0.allDay }) {
            #expect(got == want, "\(got)\n vs \(want)")
        }
        let allDay = try #require(events.first { $0.allDay })
        #expect(allDay.title == "Offsite")
        #expect(allDay.endDate.timeIntervalSince(allDay.startDate) == 86_400)
    }

    @Test func callLinks() {
        #expect(callApp("https://meet.google.com/abc") == "Google Meet")
        #expect(callApp("https://acme.zoom.us/j/1") == "Zoom")
        #expect(callApp("https://evilzoom.us/j/1") == nil)
        #expect(callApp("https://meet.google.com.example.net/x") == nil)
        #expect(callApp("http://meet.google.com/abc") == nil)
        #expect(findCallLink("see (https://meet.google.com/abc-defg-hij).") == "https://meet.google.com/abc-defg-hij")
    }
}

@Suite struct ParseTests {
    @Test func todos() {
        let md = "- [ ] Send the deck — Alex — due Fri, Nov 6 — [12:34]\n- [x] Book room\nnot a todo\n* [X] Done — Sam"
        let todos = parseTodos(md)
        #expect(todos.count == 3)
        #expect(todos[0] == Todo(line: 0, done: false, text: "Send the deck", owner: "Alex", due: "Fri, Nov 6", stamp: "12:34"))
        #expect(todos[1].done && todos[1].text == "Book room")
        #expect(todos[2].line == 3 && todos[2].owner == "Sam")
        #expect(toggleTodo(md, line: 0).hasPrefix("- [x] Send the deck"))
        #expect(toggleTodo(md, line: 1).contains("- [ ] Book room"))
    }

    @Test func typedTodos() {
        #expect(typedTodo("Send the deck - due Fri, Nov 6", owner: "Sam") == "Send the deck — Sam — due Fri, Nov 6")
        #expect(typedTodo("Send the deck - Alex - due Fri, Nov 6", owner: "Sam") == "Send the deck — Alex — due Fri, Nov 6")
        #expect(addTodo("- [ ] One\n\n", "Two") == "- [ ] One\n- [ ] Two\n")
        #expect(addTodo("", "Two") == "- [ ] Two\n")
    }

    @Test func transcripts() {
        let lines = parseTranscript("**[00:05] Sam Lee:** Hello there\n\n[1:02:03] **Alex:** Hi\n[0:20] System audio (Kim): yes\n[0:21] Microphone: me")
        #expect(lines.map(\.speaker) == ["Sam Lee", "Alex", "Kim", "Microphone"])
        #expect(lines[1].at == 3723)
        #expect(lines[2].stamp == "00:20")
    }

    @Test func notes() {
        let notes = parseNotes("- [03:09] Budget agreed\n- Prep question\n- **Date:** skip me\n")
        #expect(notes == [NoteLine(stamp: "03:09", text: "Budget agreed"), NoteLine(stamp: nil, text: "Prep question")])
    }

    @Test func previews() {
        #expect(previewOf("# Title\n- **Date:** x\n\n## Summary\n- Updates \\& **Welcomes** [12:34] [link](http://x)") == "Updates & Welcomes link")
        #expect(forReading("## Summary\nBody") == "Body")
    }

    @Test func dueDates() {
        let met = parseISO("2026-12-14T10:00:00Z")!
        let jan = dueDate("Fri, Jan 8", meetingDate: met)!
        #expect(Calendar.current.component(.year, from: jan) == 2027)
        #expect(Calendar.current.component(.month, from: dueDate("Oct 30", meetingDate: parseISO("2026-10-01T10:00:00Z"))!) == 10)
        #expect(dueDate("whenever") == nil)
    }

    @Test func clocks() {
        #expect(clock(189) == "03:09")
        #expect(clock(3729) == "1:02:09")
        #expect(seconds("1:02:03") == 3723)
    }
}

@Suite struct MeetingsTests {
    @Test func folderNames() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 5, 14, 0)
        let date = Calendar.current.date(from: c)!
        #expect(meetingFolderName(title: "Sam / Alex: 1:1", startedAt: date) == "2026-11-05 1400 Sam - Alex- 1-1")
        #expect(meetingFolderName(title: "  ", startedAt: date) == "2026-11-05 1400 Call")
        #expect(loose("Sam & Alex 1:1") == loose("Sam & Alex 1-1"))
        #expect(safeName("A/B:  C") == "A-B- C")
    }

    @Test func fileOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = Meetings(root: root)
        let team = try meetings.createFolder(in: "", named: "Team 51")
        let leads = try meetings.createFolder(in: team, named: "Leads sync")
        let m = root.appendingPathComponent("\(leads)/2026-10-29 1630 Leads sync")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try #"{"title":"Leads sync","startedAt":"2026-10-29T16:30:00.000Z"}"#.write(to: m.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        try "# Old\n- **Date:** x\n\nFirst line of prose.\n".write(to: m.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "- [ ] Do it — Alex\n".write(to: m.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        let tree = meetings.tree()
        #expect(tree.allMeetings.count == 1)
        #expect(tree.find("Team 51/Leads sync")?.meetings.first?.preview == "First line of prose.")
        #expect(matchingFolder("Team 51 – Leads sync", in: tree) == "Team 51/Leads sync")
        #expect(matchingFolder("leads SYNC!", in: tree) == "Team 51/Leads sync")
        #expect(throws: OatcakeError.self) { try resolveInside(root, "../escape") }
        #expect(throws: OatcakeError.self) { try meetings.createFolder(in: "", named: "a/b") }

        let moved = try meetings.move("Team 51/Leads sync", into: "")
        #expect(moved == "Leads sync")
        #expect(throws: OatcakeError.self) { try meetings.move("Team 51", into: "Team 51") }
        #expect(try meetings.rename("Team 51", to: "team 51") == "team 51")
        #expect(meetings.allTodos().map(\.path) == ["Leads sync/2026-10-29 1630 Leads sync"])
        #expect(try meetings.folderForEvent(title: "Leads sync", recurring: true) == "Leads sync")
        #expect(try meetings.folderForEvent(title: "Weekly: new", recurring: true) == "Weekly- new")
        #expect(try meetings.folderForEvent(title: "One-off", recurring: false) == "")
    }
}

@Suite struct AnalysisTests {
    @Test func echo() {
        let system = [Line(speaker: "A", start: 10, end: 14, text: "I think that's fine, do you agree?")]
        #expect(isEcho(Line(speaker: me, start: 11, end: 13, text: "I think that's fine"), system))
        #expect(!isEcho(Line(speaker: me, start: 15, end: 16, text: "Yes, I agree that's fine"), system))
        #expect(!isEcho(Line(speaker: me, start: 40, end: 42, text: "I think that's fine"), system))
    }

    @Test func splitsBySpeaker() {
        let words = [Word(text: "Hello", start: 0, end: 0.5), Word(text: "there.", start: 0.5, end: 1), Word(text: "Hi", start: 2.1, end: 2.4), Word(text: "!", start: 2.4, end: 2.5)]
        let turns = [Turn(start: 0, end: 1.5, speaker: "S2"), Turn(start: 2, end: 3, speaker: "S1")]
        let letters = speakerLetters(turns)
        #expect(letters == ["S2": "A", "S1": "B"])
        let lines = splitBySpeaker(Utterance(start: 0, end: 2.5, text: "Hello there. Hi!", words: words), turns: turns, letters: letters)
        #expect(lines.map(\.speaker) == ["A", "B"])
        #expect(lines.map(\.text) == ["Hello there.", "Hi!"])
    }

    @Test func csv() {
        let rows = parseCsv("a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"multi\nline\"\n\n")
        #expect(rows == [["a", "b", "c"], ["x, y", "he said \"hi\"", "multi\nline"]])
    }
}

@Suite struct UpdateTests {
    /// Signed by the Release workflow's Node script; checked here with CryptoKit.
    @Test func readsTheRealManifest() throws {
        let m = try Update.readManifest(Data(contentsOf: fixture("latest-0.3.0.json")))
        #expect(m.version == "0.3.0")
        #expect(m.bundleID == "local.oatcake")
        #expect(m.zip.name == "Oatcake-v0.3.0-arm64.zip")
    }

    @Test func refusesATamperedManifest() throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("latest-0.3.0.json"))) as! [String: String]
        var payload = String(decoding: Data(base64Encoded: json["payload"]!)!, as: UTF8.self)
        payload = payload.replacingOccurrences(of: "0.3.0", with: "9.9.9")
        json["payload"] = Data(payload.utf8).base64EncodedString()
        #expect(throws: OatcakeError.self) { try Update.readManifest(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func versions() {
        #expect(Update.compareVersions("0.10.0", "0.9.9") == 1)
        #expect(Update.compareVersions("1.0", "1.0.0") == 0)
        #expect(Update.compareVersions("0.3.0", "0.4.0") == -1)
    }
}

@Suite struct SecretsTests {
    /// Chromium's OSCrypt, as Electron's safeStorage wrote secrets.json.
    @Test func decryptsElectronSecrets() throws {
        // Made with: openssl enc -aes-128-cbc -K <PBKDF2-SHA1("pw","saltysalt",1003,16)> -iv 2020…20
        let cipher = try #require(Data(base64Encoded: "djEw/mXxrkPO2PfVblTVrGD1Ug=="))
        #expect(Secrets.decryptOSCrypt(cipher, password: "pw") == "secret")
        #expect(Secrets.decryptOSCrypt(Data("plain".utf8), password: "pw") == nil)
    }
}

@Suite struct SaveTests {
    /// The summary model can't be reached: the meeting is still saved, without summary.md.
    @Test func savesWithoutTheModel() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recDir = tmp.appendingPathComponent("rec"), root = tmp.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let analysis = Analysis(title: "Weekly sync", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Morning all."), Line(speaker: "A", start: 4, end: 6, text: "Hi Sam.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = root.path
        config.keepAudio = true
        config.llm = LlmConfig(provider: .openaiCompatible) // no endpoint: the model can't be reached
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Weekly sync", folder: "", startedAt: Date(), state: .processed)

        let saved = try await saveMeeting(config, rec, decisions: ["A": .name("Alex Kim")], folder: "") { _ in }
        #expect(saved.summaryError != nil)
        let out = root.appendingPathComponent(saved.path)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("meeting.json").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
        #expect(readText(out.appendingPathComponent("transcript.md")).contains("**[00:04] Alex Kim:** Hi Sam."))
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
        // Writing it later fails the same way while the model is still unreachable, and leaves the meeting alone.
        var failed = false
        do { try await writeSummary(config, meeting: saved.path) } catch { failed = true }
        #expect(failed)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
    }

    /// Two calls with the same title that started in the same minute are two meetings; saving one again reuses its own folder.
    @Test func sameMinuteCallsKeepTheirOwnFolders() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var config = Config.defaults()
        config.outputDir = tmp.appendingPathComponent("Meetings").path
        config.keepAudio = true
        config.llm = LlmConfig(provider: .openaiCompatible) // no endpoint: the model can't be reached
        func recording(_ id: String, at startedAt: String, saying text: String) throws -> Recording {
            let dir = tmp.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let analysis = Analysis(title: "Call", startedAt: startedAt, endedAt: startedAt, lines: [Line(speaker: me, start: 1, end: 3, text: text)],
                                    speakers: [], echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
            try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
            return Recording(id: id, dir: dir, title: "Call", folder: "", startedAt: Date(), state: .processed)
        }
        let transcript = { (path: String) in readText(config.meetingsRoot.appendingPathComponent(path).appendingPathComponent("transcript.md")) }

        let first = try await saveMeeting(config, try recording("2026-11-10T14-00-10-000Z", at: "2026-11-10T14:00:10.000Z", saying: "First call."),
                                          decisions: [:], folder: "") { _ in }
        let later = try recording("2026-11-10T14-00-45-000Z", at: "2026-11-10T14:00:45.000Z", saying: "Second call.")
        let second = try await saveMeeting(config, later, decisions: [:], folder: "") { _ in }
        #expect(second.path == first.path + " (2)")
        #expect(transcript(first.path).contains("First call."))
        #expect(transcript(second.path).contains("Second call."))

        let again = try await saveMeeting(config, later, decisions: [:], folder: "") { _ in }
        #expect(again.path == second.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.outputDir).count == 2)
    }
}

@Suite struct EnvironmentTests {
    /// Claude Code never gets Oatcake's API keys; the analysis helper does, as a key from your shell is its fallback too.
    @Test func childEnvironments() {
        let name = "OATCAKE_OPENAI_API_KEY"
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, "from-the-shell", 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        #expect(ShellEnvironment.childEnvironment()[name] == nil)
        #expect(ShellEnvironment.childEnvironment(keepApiKeys: true)[name] == "from-the-shell")
        #expect(ShellEnvironment.childEnvironment()["PATH"] == ShellEnvironment.path)
    }
}

@Suite struct VoiceprintTests {
    @Test func renamesAndMerges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sample = { (call: String, at: String) in Voiceprints.Sample(embedding: [1, 0], call: call, at: at) }
        try Voiceprints(model: voiceprintModel, people: [
            "Nate": .init(samples: [sample("a", "2026-11-01T10:00:00.000Z"), sample("b", "2026-11-03T10:00:00.000Z")]),
            "Nate Allen": .init(samples: [sample("c", "2026-11-02T10:00:00.000Z")]),
            "Alex": .init(samples: [sample("d", "2026-11-04T10:00:00.000Z")]),
        ]).save(file)

        try renameVoice("Nate", to: "  Nate Allen ", file: file)
        let voices = knownVoices(file)
        #expect(voices.map(\.name) == ["Alex", "Nate Allen"])
        #expect(Voiceprints.load(file).people["Nate Allen"]?.samples.map(\.call) == ["a", "c", "b"])
        #expect(voices.last?.calls == 3)
        #expect(throws: OatcakeError.self) { try renameVoice("Nobody", to: "X", file: file) }
        #expect(throws: OatcakeError.self) { try renameVoice("Alex", to: " ", file: file) }

        try forgetVoice("Alex", file: file)
        #expect(knownVoices(file).map(\.name) == ["Nate Allen"])
    }
}
