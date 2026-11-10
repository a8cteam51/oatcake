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

    /// Who's on an invite keeps how they answered and whether they're a room, so neither is offered as a name.
    @Test func attendees() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:1
        SUMMARY:Planning
        DTSTART:20261110T100000Z
        DTEND:20261110T103000Z
        ATTENDEE;CN=Alex Kim;PARTSTAT=ACCEPTED:mailto:alex@example.com
        ATTENDEE;CN=Jo Park;PARTSTAT=DECLINED:mailto:jo@example.com
        ATTENDEE;CUTYPE=RESOURCE;CN=London-6-Boardroom (10):mailto:room@resource.calendar.example.com
        END:VEVENT
        END:VCALENDAR
        """
        let event = try #require(parseCalendar(ics, from: parseISO("2026-11-10T00:00:00Z")!, to: parseISO("2026-11-11T00:00:00Z")!).first)
        #expect(event.attendees.map(\.email) == ["alex@example.com", "jo@example.com", "room@resource.calendar.example.com"])
        #expect(event.attendees.map(\.declined) == [nil, true, nil])
        #expect(event.attendees.map(\.resource) == [nil, nil, true])
        // A cache written before these were kept still reads.
        let old = try JSONDecoder().decode(CalendarEvent.Attendee.self, from: Data(#"{"name":"Alex Kim","email":"alex@example.com"}"#.utf8))
        #expect(old == event.attendees[0] && old.declined == nil)
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

        // Renaming a meeting changes its title and its folder's name, and keeps meeting.json's other keys.
        let meeting = "Leads sync/2026-10-29 1630 Leads sync"
        try #"{"title":"Leads sync","startedAt":"2026-10-29T16:30:00.000Z","recording":"r1","granolaNote":"https://notes.granola.ai/d/x"}"#
            .write(to: root.appendingPathComponent(meeting + "/meeting.json"), atomically: true, encoding: .utf8)
        let renamed = try meetings.retitle(meeting, to: "Leads: Q4 plan")
        #expect(renamed == "Leads sync/2026-10-29 1630 Leads- Q4 plan")
        let node = try #require(meetings.tree().find(renamed))
        #expect(node.title == "Leads: Q4 plan" && node.startedAt != nil)
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(renamed + "/meeting.json"))) as? [String: String]
        #expect(kept?["recording"] == "r1" && kept?["granolaNote"] == "https://notes.granola.ai/d/x")
        #expect(throws: OatcakeError.self) { try meetings.retitle(renamed, to: "  ") }
    }

    @Test func eventsGoWhereTheirEarlierMeetingsAre() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-event-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func meeting(_ rel: String, _ title: String, _ started: String) throws {
            let dir = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"title":"\#(title)","startedAt":"\#(started)"}"#.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        }
        try meeting("Old/2026-10-05 1000 Weekly sync", "Weekly sync", "2026-10-05T10:00:00.000Z")
        try meeting("Team/2026-11-09 1000 Weekly sync", "Weekly Sync!", "2026-11-09T10:00:00.000Z")
        try meeting("2026-11-03 0900 Coffee", "Coffee", "2026-11-03T09:00:00.000Z")
        let meetings = Meetings(root: root)
        // No folder is called "Weekly sync", so it goes where the latest one is, recurring or not.
        #expect(try meetings.folderForEvent(title: "Weekly sync", recurring: true) == "Team")
        #expect(try meetings.folderForEvent(title: "weekly sync", recurring: false) == "Team")
        // The latest "Coffee" is at the top level, so no folder is made for it.
        #expect(try meetings.folderForEvent(title: "Coffee", recurring: true) == "")
        // A folder named like the event still comes first, and a new recurring event still gets its own.
        _ = try meetings.createFolder(in: "Team", named: "Weekly sync")
        #expect(try meetings.folderForEvent(title: "Weekly sync", recurring: false) == "Team/Weekly sync")
        #expect(try meetings.folderForEvent(title: "Board prep", recurring: true) == "Board prep")
        #expect(try meetings.folderForEvent(title: "One-off chat", recurring: false) == "")
    }

    @Test func searchesEveryMeetingsText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ file: MeetingFile, _ text: String) throws {
            let dir = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            try text.write(to: dir.appendingPathComponent(file.rawValue), atomically: true, encoding: .utf8)
        }
        let sync = "Team/2026-11-09 1000 Weekly sync", review = "Design/2026-11-06 1400 Design review"
        try write(sync, .summary, "## Launch plan\n\nAlex said the checklist is nearly done.\n")
        try write(sync, .transcript, "**[00:00] Sam:** Morning.\n\n**[12:34] Alex:** For the offsite in March I think that we could all meet up at the Café Lumière, if the budget allows.\n")
        try write(review, .notes, "- [02:10] Ask about the colour tokens\n")
        try write(review, .todo, "- [ ] Send the deck — Alex — [04:20]\n")
        let meetings = Meetings(root: root)
        let all = [(path: sync, label: "Weekly sync Team"), (path: review, label: "Design review Design")]

        // In a transcript, whatever the case or accents: the line, starting near the words, and its time.
        let cafe = meetings.search("cafe LUMIERE", in: all)
        #expect(cafe.map(\.path) == [sync])
        #expect(cafe.first?.file == .transcript && cafe.first?.stamp == "12:34")
        #expect(cafe.first?.line.hasPrefix("Alex: …") == true && cafe.first?.line.contains("meet up at the Café Lumière") == true)
        // A search for someone's name finds where they speak.
        #expect(meetings.search("sam", in: all).first == SearchHit(path: sync, file: .transcript, line: "Sam: Morning.", stamp: "00:00"))
        // Notes and to-dos are looked through as well, and a line is shown as plain text.
        #expect(meetings.search("tokens", in: all).first?.file == .notes)
        #expect(meetings.search("deck", in: all).first == SearchHit(path: review, file: .todo, line: "Send the deck — Alex"))
        // Words can be split between the title and the text, and every one of them is needed.
        #expect(meetings.search("weekly checklist", in: all).first == SearchHit(path: sync, file: .summary, line: "Alex said the checklist is nearly done."))
        #expect(meetings.search("weekly deck", in: all).isEmpty)
        // All in the title or folder: found, with no line to show.
        #expect(meetings.search("design review", in: all) == [SearchHit(path: review)])
        #expect(meetings.search("   ", in: all).isEmpty)
        // A file that changes is read again.
        try write(sync, .summary, "## Hiring\n\nThe zebra budget was agreed.\n")
        #expect(meetings.search("zebra", in: all).first?.line == "The zebra budget was agreed.")
        #expect(meetings.search("checklist", in: all).isEmpty)
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
    /// Saving involves no model: the meeting is written, and its summary is a separate step that can fail and be tried again.
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

        let saved = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim")], folder: "")
        let out = root.appendingPathComponent(saved)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("meeting.json").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
        #expect(readText(out.appendingPathComponent("transcript.md")).contains("**[00:04] Alex Kim:** Hi Sam."))
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
        // Writing the summary fails while the model is unreachable, and leaves the meeting alone.
        var failed = false
        do { try await writeSummary(config, meeting: saved) } catch { failed = true }
        #expect(failed)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))

        // When the model has answered, its summary goes where the meeting is by then (it was renamed
        // meanwhile), and a to-do added in the meantime is kept above the model's.
        let meetings = Meetings(root: root)
        let renamed = try meetings.retitle(saved, to: "Weekly sync with Alex")
        try meetings.write(renamed, .todo, "- [ ] Added while the model was writing\n")
        try writeSummary(SummaryDraft(summary: "## Topic\nDone.\n", todo: "- [ ] From the model — Alex Kim\n"), config: config, meeting: renamed)
        let files = try meetings.read(renamed)
        #expect(files.summary == "## Topic\nDone.\n")
        #expect(files.todo == "- [ ] Added while the model was writing\n- [ ] From the model — Alex Kim\n")
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

        let first = try saveMeeting(config, try recording("2026-11-10T14-00-10-000Z", at: "2026-11-10T14:00:10.000Z", saying: "First call."),
                                    decisions: [:], folder: "")
        let later = try recording("2026-11-10T14-00-45-000Z", at: "2026-11-10T14:00:45.000Z", saying: "Second call.")
        let second = try saveMeeting(config, later, decisions: [:], folder: "")
        #expect(second == first + " (2)")
        #expect(transcript(first).contains("First call."))
        #expect(transcript(second).contains("Second call."))

        let again = try saveMeeting(config, later, decisions: [:], folder: "")
        #expect(again == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.outputDir).count == 2)
    }

    /// The title and folder chosen in review are the ones saved, and a long turn is split at pauses.
    @Test func savesUnderTheReviewedTitleInShorterParagraphs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = tmp.appendingPathComponent("Meetings").path
        config.keepAudio = true
        let dir = tmp.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One person talking for 80 s in ten-second stretches with half-second pauses, then a reply.
        let turn = (0..<8).map { Line(speaker: "A", start: Double($0) * 10, end: Double($0) * 10 + 9.5, text: "Part \($0 + 1).") }
        let analysis = Analysis(title: "Call", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:02:00.000Z",
                                lines: turn + [Line(speaker: me, start: 82, end: 84, text: "Thanks.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 76, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: dir, title: "Call", folder: "", startedAt: Date(), state: .processed)

        let path = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim")], folder: "Clients/Acme", title: "  Acme kickoff ")
        #expect(path.hasPrefix("Clients/Acme/") && path.hasSuffix(" Acme kickoff"))
        let files = try Meetings(root: config.meetingsRoot).read(path)
        #expect(files.meta.title == "Acme kickoff")
        let paragraphs = parseTranscript(files.transcript)
        #expect(paragraphs.map(\.speaker) == ["Alex Kim", "Alex Kim", "Alex Kim", "Sam Taylor"])
        #expect(paragraphs.map(\.stamp) == ["00:00", "00:30", "01:00", "01:22"])
        #expect(paragraphs[0].text == "Part 1. Part 2. Part 3.")
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

@Suite struct ModelErrorTests {
    @Test func plainWords() {
        let unknown = explainModelError(#"claude exited 1: [claude-code:unrecognized_model] {"model":"claude-fable-5-2","query_source":"sdk"}"#)
        #expect(unknown.contains("“claude-fable-5-2”") && unknown.contains("Settings › Summaries"))
        #expect(explainModelError("Could not connect to the server.").contains("couldn’t be reached"))
        #expect(explainModelError("claude exited 1: Invalid API key · Please run /login").contains("/login"))
        #expect(explainModelError("The Anthropic API returned 429: rate limit exceeded").contains("usage limit"))
        // Already plain: unchanged.
        #expect(explainModelError("Add an Anthropic API key in Settings first.") == "Add an Anthropic API key in Settings first.")
    }

    @Test func jargon() {
        var config = Config.defaults()
        #expect(config.jargonLine.isEmpty)
        config.jargon = ["Automattic", " ", "WooCommerce"]
        #expect(config.jargonLine.hasSuffix("Automattic, WooCommerce."))
    }

    /// A config written by an earlier version has none of the newer settings: they take their defaults.
    @Test func partProviderSettings() throws {
        // A provider's settings with a key missing keep the keys that are there.
        let json = #"{"provider":"openai-compatible","openai":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1"},"anthropic":{"effort":"high"}}"#
        let llm = try JSONDecoder().decode(LlmConfig.self, from: Data(json.utf8))
        #expect(llm.provider == .openaiCompatible)
        #expect(llm.openai.baseUrl == "http://localhost:11434/v1" && llm.openai.model == "llama3.1" && llm.openai.effort == .medium)
        #expect(llm.anthropic.effort == .high && llm.anthropic.model == anthropicModels[0])
        #expect(llm.claudeCode == LlmConfig.ClaudeCode())
    }

    @Test func olderConfig() throws {
        let old = #"{"myName":"Sam","outputDir":"/tmp/m","asrModel":"parakeet-unified-en","keepAudio":false,"mic":null,"callReminders":false,"updateCheck":true}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.callNotice && config.autoStop && config.liveTranscript && config.menuBarNextCall && config.jargon.isEmpty)
        #expect(!config.callReminders && config.myName == "Sam")
        let again = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.autoStop = false; $0.jargon = ["Jetpack"] }).utf8))
        #expect(!again.autoStop && again.jargon == ["Jetpack"])
    }
}

@Suite struct CallTests {
    @Test func callingApps() {
        #expect(CallDetector.callingApp("com.google.Chrome.helper") == "Google Chrome")
        #expect(CallDetector.callingApp("us.zoom.xos") == "Zoom")
        #expect(CallDetector.callingApp("com.apple.WebKit.GPU") == "Safari")
        #expect(CallDetector.callingApp("com.apple.CoreSpeech") == nil)
        #expect(CallDetector.callingApp("local.oatcake.recorder") == nil)
        #expect(CallDetector.callingApp("com.google.Chromecast") == nil)
    }

    /// The live transcript drops a microphone line that only repeats the call audio, and reads in time order.
    @Test func liveLines() {
        let lines = [
            LiveTranscriptLine(track: .mic, start: 12.4, end: 15, text: "I think that's fine, do you agree?"),
            LiveTranscriptLine(track: .system, start: 12, end: 15, text: "I think that's fine, do you agree?"),
            LiveTranscriptLine(track: .mic, start: 16, end: 17, text: "Yes, sounds good to me."),
            LiveTranscriptLine(track: .system, start: 2, end: 4, text: "Morning everyone."),
        ]
        #expect(liveTranscript(lines).map(\.text) == ["Morning everyone.", "I think that's fine, do you agree?", "Yes, sounds good to me."])
        // Each line on the call side gets a made-up name of its own: kept for that line, and never the one before it.
        let names = [4.1, 12.4, 25.0, 33.1, 48.0, 56.2].map { callPlaceholder(for: "a", lineAt: $0) }
        #expect(names.allSatisfy(callPlaceholders.contains))
        #expect(zip(names, names.dropFirst()).allSatisfy { $0 != $1 })
        #expect(callPlaceholder(for: "a", lineAt: 12.4) == names[1])
    }
}

private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}
