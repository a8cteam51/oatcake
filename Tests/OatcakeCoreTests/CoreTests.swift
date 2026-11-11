import CryptoKit
import Foundation
import Network
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
        config.llm = LlmConfig(model: LlmConfig.ownServer) // no endpoint: the model can't be reached
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
        config.llm = LlmConfig(model: LlmConfig.ownServer) // no endpoint: the model can't be reached
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
    /// Oatcake's helpers (and the language model's server) don't get the calendar's private address.
    @Test func childEnvironments() {
        let name = "OATCAKE_CALENDAR_URL"
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, "https://calendar.example.com/private.ics", 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        #expect(ShellEnvironment.childEnvironment()[name] == nil)
        #expect(ShellEnvironment.childEnvironment()["PATH"] == ProcessInfo.processInfo.environment["PATH"])
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
        let unknown = explainModelError(#"The model at http://localhost:11434/v1 returned 404: {"error":{"message":"model \"qwen9\" not found, try pulling it first"}}"#)
        #expect(unknown.contains("isn’t on that server") && unknown.contains("Settings › Summaries"))
        #expect(explainModelError("Could not connect to the server.").contains("couldn’t be reached"))
        #expect(explainModelError(#"The model at http://127.0.0.1:5000/v1 returned 400: {"error":{"message":"the request exceeds the available context size"}}"#).contains("too long"))
        // Already plain: unchanged.
        for plain in [notLocalMessage, modelNotDownloadedMessage, outOfRoomMessage, "Set the endpoint and model in Settings first."] {
            #expect(explainModelError(plain) == plain)
        }
    }

    @Test func jargon() {
        var config = Config.defaults()
        #expect(config.jargonLine.isEmpty)
        config.jargon = ["Automattic", " ", "WooCommerce"]
        #expect(config.jargonLine.hasSuffix("Automattic, WooCommerce."))
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
        // The summary's instructions are Oatcake's own until you write yours.
        var config = Config.defaults()
        #expect(config.summaryTask == defaultSummaryInstructions)
        config.summaryInstructions = "  Three bullet points, in French.\n"
        #expect(config.summaryTask == "Three bullet points, in French.")
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(config).utf8)).summaryInstructions == config.summaryInstructions)
    }

    @Test func localModelsOnly() async throws {
        // This Mac, a machine on your network, or a private address.
        for address in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", "http://mac-studio:11434/v1",
                        "http://studio.local:11434/v1", "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "https://172.20.1.1/v1"] {
            #expect(isLocalEndpoint(address), "\(address)")
        }
        // Anyone else's service, or not an address at all.
        for address in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1",
                        "https://localhost.example.com/v1", "ftp://localhost/v1", "localhost:11434", ""] {
            #expect(!isLocalEndpoint(address), "\(address)")
        }
        // A server of your own pointed somewhere else is refused before anything is sent.
        var config = LlmConfig(model: LlmConfig.ownServer)
        config.own.baseUrl = "https://api.openai.com/v1"
        config.own.model = "gpt"
        await #expect(throws: OatcakeError(notLocalMessage)) {
            _ = try await withModel(config, tokens: 100) { chat, _ in try await chat.complete([ChatMessage("user", "Hello")]) }
        }
        // No key is kept for a model any more.
        #expect(SecretName.allCases.map(\.rawValue) == ["calendar"])
    }

    /// Which model a Mac starts with, and how much it's given to read at once, go by its memory.
    @Test func modelsByMemory() {
        let big = LocalModels.all[0], small = LocalModels.all[1]
        #expect(LocalModels.recommended(memory: 8) == small && LocalModels.recommended(memory: 16) == big && LocalModels.recommended(memory: 36) == big)
        #expect(!LocalModels.fits(big, memory: 8) && LocalModels.fits(small, memory: 8) && LocalModels.fits(big, memory: 16))
        #expect(LocalModels.maxContext(small, memory: 8) == 16_384)
        #expect(LocalModels.maxContext(big, memory: 16) == 32_768)
        #expect(LocalModels.maxContext(big, memory: 36) == 131_072)
        // The smallest window that holds the job, so no more memory is taken than it needs.
        #expect(LocalModels.context(forTokens: 3_000) == 8_192 && LocalModels.context(forTokens: 20_000) == 24_576)
        #expect(LocalModels.context(forTokens: 500_000) == 131_072)
        // A window stretched past the model's own is for a text that needs it: a job that fits never
        // borrows a server that's running stretched, and a bigger window of the same kind is shared.
        #expect(LocalModels.stretch(32_768) == 1 && LocalModels.stretch(49_152) == 2 && LocalModels.stretch(131_072) == 4)
        #expect(LocalModels.serves(running: 32_768, needed: 8_192) && LocalModels.serves(running: 65_536, needed: 49_152))
        #expect(!LocalModels.serves(running: 49_152, needed: 32_768) && !LocalModels.serves(running: 16_384, needed: 32_768))
        // The files are the ones that were measured: a fixed revision, with its size and checksum.
        for model in LocalModels.all {
            #expect(model.url.hasPrefix("https://huggingface.co/Qwen/") && model.url.contains("/resolve/") && model.url.hasSuffix(model.file))
            #expect(model.sha256.count == 64 && model.bytes > 2_000_000_000)
        }
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

/// A small HTTP server on this Mac's own address, standing in for the language model's server (and
/// for the site a model is downloaded from). It answers each request with what `handler` returns.
final class StandIn: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        /// The system and user messages of a chat request.
        var messages: (system: String, user: String) {
            let all = json["messages"] as? [[String: Any]] ?? []
            func content(_ role: String) -> String { all.last { $0["role"] as? String == role }?["content"] as? String ?? "" }
            return (content("system"), content("user"))
        }
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// A chat completion whose message is `content`.
        static func chat(_ content: String) -> Response {
            let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
            return Response(body: try! JSONSerialization.data(withJSONObject: json))
        }
    }

    private let listener: NWListener
    private let handler: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var seen: [Request] = []
    var requests: [Request] { lock.withLock { seen } }
    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var address: String { "http://127.0.0.1:\(port)" }

    init(_ handler: @escaping @Sendable (Request) -> Response) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let listener = listener
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }

    /// A model server that answers each chat request with what `reply` returns.
    static func model(_ reply: @escaping @Sendable (Request) -> String) async throws -> StandIn {
        try await StandIn { .chat(reply($0)) }
    }

    /// Settings that send every request for the model here.
    var config: Config {
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.llm = LlmConfig(model: LlmConfig.ownServer)
        config.llm.own.baseUrl = address + "/v1"
        config.llm.own.model = "stand-in"
        return config
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        var buffer = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.lock.withLock { self.seen.append(request) }
                    let response = self.handler(request)
                    var head = "HTTP/1.1 \(response.status) OK\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                    for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
                    connection.send(content: Data((head + "\r\n").utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    /// A whole request, once all of it has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmed
        }
        let body = data[end.upperBound...]
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }
        let first = lines.first?.split(separator: " ") ?? []
        return Request(path: first.count > 1 ? String(first[1]) : "", headers: headers, body: Data(body))
    }
}

/// A Meetings folder for a test, with a way to put meetings in it.
private struct TestMeetings {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-model-\(UUID().uuidString)")

    func write(_ rel: String, _ file: MeetingFile, _ text: String, meta: String = "{}") throws {
        let dir = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.json").path) {
            try meta.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        }
        try text.write(to: dir.appendingPathComponent(file.rawValue), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct LocalModelTests {
    /// What goes to the model's server: Qwen's own sampling for each mode, its reasoning switch, the
    /// shape a reply must fit, and the key Oatcake made up for its own server.
    @Test func requests() async throws {
        let server = try await StandIn.model { _ in "<think>\nLet me see.\n</think>\n\nOK" }
        let own = LocalChat(baseUrl: server.address + "/v1", model: "qwen3-8b", key: "made-up", qwen: true)
        #expect(await own.isReady() && server.requests.last?.path == "/health")
        #expect(try await own.complete([ChatMessage("system", "Be brief."), ChatMessage("user", "Say OK.")], schema: todosSchema) == "OK")
        #expect(try await own.complete([ChatMessage("user", "Say OK.")], think: false, maxTokens: 20) == "OK")
        let sent = server.requests.filter { $0.path == "/v1/chat/completions" }
        #expect(sent.count == 2 && sent.allSatisfy { $0.headers["authorization"] == "Bearer made-up" })
        let thinking = sent[0].json, plain = sent[1].json
        #expect(thinking["temperature"] as? Double == 0.6 && thinking["top_p"] as? Double == 0.95 && thinking["top_k"] as? Int == 20)
        #expect(thinking["presence_penalty"] as? Double == 1.5 && thinking["min_p"] as? Int == 0 && thinking["cache_prompt"] as? Bool == true)
        #expect((thinking["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect(((thinking["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] != nil)
        #expect(thinking["max_tokens"] as? Int == 8_192 && sent[0].messages.system == "Be brief.")
        #expect(plain["temperature"] as? Double == 0.7 && plain["top_p"] as? Double == 0.8 && plain["max_tokens"] as? Int == 20)
        #expect((plain["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false && plain["response_format"] == nil)

        // A server of your own gets no key and no switch it may not know.
        let yours = try await withModel(server.config.llm, tokens: 100) { chat, context in
            #expect(context == LocalModels.nativeContext)
            return try await chat.complete([ChatMessage("user", "Say OK.")])
        }
        #expect(yours == "OK" && server.requests.last?.headers["authorization"] == nil && server.requests.last?.json["chat_template_kwargs"] == nil)

        // A reply that's all reasoning, cut off before the answer, is an error rather than an empty summary.
        let cut = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8))
        }
        await #expect(throws: OatcakeError(outOfRoomMessage)) {
            _ = try await LocalChat(baseUrl: cut.address + "/v1", model: "m").complete([ChatMessage("user", "Hello")])
        }
    }

    /// A summary is two requests about the same transcript: the summary, following the instructions
    /// in Settings, then the to-dos as JSON. The second begins exactly as the first did, which is what
    /// lets the model answer it without reading the transcript again.
    @Test func summaryAndTodos() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] Sam Taylor:** Morning. Alex, where are we with the deck?\n\n**[00:04] Alex Kim:** I will send the deck on Friday.\n",
                           meta: #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z","participants":["Sam Taylor","Alex Kim"]}"#)
        try meetings.write(rel, .notes, "- [00:03] Deck timing\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "Here is the summary.\n\n## Deck\n- Alex Kim will send the deck on Friday.\n"
                : #"{"todos":[{"task":"send the deck","owner":"Alex Kim","due":"Friday","at":"[00:04]"},{"task":"Book a room","owner":"null","due":null,"at":null}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.jargon = ["WooCommerce"]
        config.summaryInstructions = "Write three bullet points, in French."

        let draft = try await draftSummary(config, meeting: rel)
        #expect(draft.summary == "## Deck\n- Alex Kim will send the deck on Friday.\n")
        #expect(draft.todo == "- [ ] Send the deck — Alex Kim — due Friday — [00:04]\n- [ ] Book a room\n")
        let sent = server.requests.map(\.messages)
        #expect(sent.count == 2 && sent[0].system == sent[1].system)
        #expect(sent[0].user.hasSuffix("Write three bullet points, in French.") && !sent[0].user.contains("Cover every topic"))
        #expect(sent[1].user.contains(#"{"todos": ["#) && server.requests[0].json["response_format"] == nil)
        let shared = try #require(sent[0].user.range(of: "I will send the deck on Friday.\n\n")).upperBound
        #expect(sent[1].user.hasPrefix(sent[0].user[..<shared]))
        #expect(sent[0].user.hasPrefix("Meeting: Weekly sync\nParticipants: Sam Taylor, Alex Kim\n") && sent[0].user.contains("WooCommerce") && sent[0].user.contains("[00:03] Deck timing"))
        // The summary is reasoned over and the to-dos aren't, until Settings says otherwise: 0.6 is Qwen's sampling with reasoning, 0.7 without.
        #expect(server.requests.map { $0.json["temperature"] as? Double } == [0.6, 0.7])

        // Oatcake's own instructions when there are none of yours.
        config.summaryInstructions = ""
        config.llm.reasoning.summary = false
        config.llm.reasoning.todos = true
        _ = try await draftSummary(config, meeting: rel)
        #expect(server.requests[2].messages.user.hasSuffix(defaultSummaryInstructions))
        #expect(server.requests[2...].map { $0.json["temperature"] as? Double } == [0.7, 0.6])
    }

    @Test func summaryPieces() {
        // Anything before the first heading goes, and a code fence around the lot.
        #expect(summaryBody("Sure!\n\n## Launch\n- Done.\n") == "## Launch\n- Done.")
        #expect(summaryBody("```markdown\n## Launch\n- Done.\n```") == "## Launch\n- Done.")
        #expect(summaryBody("Three points, as asked.") == "Three points, as asked.")
        // To-dos: what the model didn't know is left out, however it said so.
        let lines = todoLines(#"Here: {"todos":[{"task":"email Priya the figures","owner":"Sam","due":"none","at":"1:02:03"},{"task":"","owner":"Alex","due":null,"at":null},{"task":"Review — the plan","owner":"N/A","due":"Fri, Oct 30","at":"soon"}]}"#)
        #expect(lines == ["- [ ] Email Priya the figures — Sam — [1:02:03]", "- [ ] Review, the plan — due Fri, Oct 30"])
        #expect(todoLines("no JSON here").isEmpty && todoLines(#"{"todos":[]}"#).isEmpty)
        // A long call is cut between turns, and nothing is lost or repeated.
        let turns = (0..<40).map { "**[\(clock(Double($0) * 30))] Alex:** " + String(repeating: "word ", count: 60).trimmed }
        let whole = turns.joined(separator: "\n\n")
        let parts = splitTranscript(whole, tokens: 800)
        #expect(parts.count > 3 && parts.joined(separator: "\n\n") == whole)
        #expect(parts.allSatisfy { LocalModels.tokens(in: $0) <= 800 })
        #expect(splitTranscript(whole, tokens: 100_000) == [whole])
    }

    /// A name is only suggested when it was said: a small model asked for one will sometimes invent it.
    @Test func suggestedNames() async throws {
        let transcript = "Sam Taylor (recorder): Priya, where are we with pricing?\nSpeaker A: Nearly there.\nSpeaker B: I agree with Priya."
        let reply = #"{"speakers":[{"speaker":"Speaker A","name":"Priya","quote":"Priya, where are we"},{"speaker":"B","name":"Jordan Lee","quote":null},{"speaker":"C","name":"Sam","quote":"x"},{"speaker":"Z","name":"Priya","quote":"x"}]}"#
        let names = namesIn(reply, unknown: ["A", "B", "C"], transcript: transcript, myName: "Sam Taylor")
        // B's name was never said, C's is your own, and Z wasn't asked about.
        #expect(names == ["A": Suggestion(name: "Priya", how: .transcript, detail: "Priya, where are we")])
        #expect(namesIn(#"{"speakers":[{"speaker":"A","name":"null","quote":"null"},{"speaker":"B","name":"Speaker B","quote":null}]}"#, unknown: ["A", "B"], transcript: transcript, myName: "Sam Taylor").isEmpty)
        // Said means said as a word: "Dan" isn't in "abundant", and "Ann" isn't in "announce". A name in two parts is.
        let said = "Sam Taylor (recorder): Jean-Luc, the evidence is abundant.\nSpeaker A: I will announce it.\nSpeaker B: Fine."
        let made = #"{"speakers":[{"speaker":"A","name":"Dan","quote":null},{"speaker":"B","name":"Ann","quote":null},{"speaker":"C","name":"Jean-Luc","quote":"Jean-Luc, the evidence"}]}"#
        #expect(namesIn(made, unknown: ["A", "B", "C"], transcript: said, myName: "Sam Taylor").mapValues(\.name) == ["C": "Jean-Luc"])

        // From a processed recording: the voice nobody recognised gets its name, one that was recognised keeps its own.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Suggestion(name: "Alex Kim", how: .voice, detail: "voice match 0.81")
        let analysis = Analysis(title: "Pricing", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Priya, where are we with pricing?"), Line(speaker: "A", start: 4, end: 6, text: "Nearly there."),
                                        Line(speaker: "B", start: 7, end: 9, text: "Good.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: []),
                                           SpeakerInfo(id: "B", seconds: 30, embedding: nil, suggestion: known, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        #expect(hasUnnamedVoices(dir))
        let server = try await StandIn.model { _ in #"{"speakers":[{"speaker":"A","name":"Priya","quote":"Priya, where are we"},{"speaker":"B","name":"Priya","quote":null}]}"# }
        await suggestNames(dir, config: server.config)
        let named = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(named.speakers.map(\.suggestion?.name) == ["Priya", "Alex Kim"] && named.warnings.isEmpty && !hasUnnamedVoices(dir))
        let asked = try #require(server.requests.first)
        #expect(asked.messages.user.contains("Sam Taylor (recorder): Priya, where are we with pricing?\nSpeaker A: Nearly there.\nAlex Kim: Good."))
        #expect(asked.messages.user.contains("Unidentified speakers: Speaker A\n") && asked.json["response_format"] != nil)
        #expect(asked.json["temperature"] as? Double == 0.6)

        // A model that can't be reached is noted for the review screen, and the analysis is left as it was.
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let broken = try await StandIn { _ in StandIn.Response(status: 500, body: Data("no".utf8)) }
        await suggestNames(dir, config: broken.config)
        let skipped = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(skipped.speakers[0].suggestion == nil && skipped.warnings.first?.hasPrefix("Name suggestions skipped: ") == true)
    }

    /// Ask: the open meeting whole, then (only when the model says the question reaches beyond it)
    /// what a search of the others finds. The model's tags become links to the meetings and times.
    @Test func ask() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let sync = "Team/2026-11-09 1000 Weekly sync", earlier = "Team/2026-11-02 1000 Weekly sync", review = "Design/2026-11-06 1400 Design review"
        try meetings.write(sync, .transcript, "**[00:00] Sam Taylor:** Morning.\n\n**[12:34] Alex Kim:** I will book the café for the offsite.\n",
                           meta: #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z","participants":["Sam Taylor","Alex Kim"]}"#)
        try meetings.write(sync, .todo, "- [x] Book the café — Alex Kim\n")
        var config = Config.defaults()
        config.outputDir = meetings.root.path

        // On its own: one request, and a bare time can only be in this meeting.
        let alone = try await StandIn.model { _ in "Alex Kim said he would book it [M1 12:34], which is done [M1]. See also [00:00]. A link: [x](https://example.com)." }
        config.llm = alone.config.llm
        let first = try await OatcakeCore.ask(config, meeting: sync, question: "Who is booking the café?")
        let here = "Team/2026-11-09%201000%20Weekly%20sync"
        #expect(first == "Alex Kim said he would book it [12:34](\(here)#12:34), which is done [Weekly sync · Nov 9](\(here)). See also [00:00](\(here)#00:00). A link: [x](https://example.com).")
        #expect(alone.requests.count == 1 && alone.requests[0].json["temperature"] as? Double == 0.6)
        let only = alone.requests[0].messages
        #expect(only.system.contains("[M1 12:34]") && only.user.hasPrefix("[M1] Weekly sync · Mon, Nov 9, 2026 (the meeting "))
        #expect(only.user.contains("To-dos ([x] = done):\n- [x] Book the café — Alex Kim") && only.user.contains("**[12:34] Alex Kim:** I will book the café"))
        #expect(only.user.hasSuffix("Question: Who is booking the café?"))

        // With other meetings: the model is asked first whether the question reaches them.
        try meetings.write(earlier, .summary, "## Offsite\n- The offsite is in March.\n", meta: #"{"title":"Weekly sync","startedAt":"2026-11-02T10:00:00.000Z"}"#)
        try meetings.write(earlier, .transcript, "**[03:10] Alex Kim:** The offsite budget is five thousand.\n\n**[04:00] Sam Taylor:** Fine.\n")
        try meetings.write(review, .summary, "## Colours\n- New tokens agreed.\n", meta: #"{"title":"Design review","startedAt":"2026-11-06T14:00:00.000Z"}"#)
        let stays = try await StandIn.model { $0.json["response_format"] != nil ? #"{"beyond":false,"search":[]}"# : "Alex Kim [M1 12:34]." }
        config.llm = stays.config.llm
        config.llm.reasoning.ask = false
        _ = try await OatcakeCore.ask(config, meeting: sync, question: "Who is booking the café?")
        #expect(stays.requests.count == 2 && !stays.requests[1].messages.user.contains("[M2]"))
        #expect(stays.requests.map { $0.json["temperature"] as? Double } == [0.7, 0.7])

        let reaches = try await StandIn.model {
            $0.json["response_format"] != nil ? #"{"beyond":true,"search":["offsite budget","zebra"]}"#
                : "The budget is five thousand [M2 03:10], and Alex Kim is booking the café [M1, 12:34]. Nothing on colours [M3]. Not [M7]."
        }
        config.llm = reaches.config.llm
        let history = [AskExchange(question: "Who is booking the café?", answer: "Alex Kim [12:34](\(here)#12:34).")]
        let second = try await OatcakeCore.ask(config, meeting: sync, question: "What was the budget for the offsite?", history: history)
        let before = "Team/2026-11-02%201000%20Weekly%20sync"
        #expect(second == "The budget is five thousand [Weekly sync · Nov 2 · 03:10](\(before)#03:10), and Alex Kim is booking the café [12:34](\(here)#12:34). Nothing on colours [M3]. Not [M7].")
        let route = reaches.requests[0].messages.user, answer = reaches.requests[1].messages.user
        // Both begin with the open meeting, word for word: read once, kept for the answer and the next question.
        let open = try #require(route.range(of: "I will book the café for the offsite.")).upperBound
        #expect(answer.hasPrefix(route[..<open]) && route.hasSuffix("when \"beyond\" is false."))
        // The earlier meeting in the series was found by the search; the design review, which has neither phrase, wasn't.
        #expect(answer.contains("[M2] Weekly sync · Mon, Nov 2, 2026\n") && answer.contains("- The offsite is in March."))
        #expect(answer.contains("**[03:10] Alex Kim:** The offsite budget is five thousand.") && !answer.contains("**[04:00]") && !answer.contains("Design review"))
        #expect(answer.contains("Earlier in this conversation:\nQuestion: Who is booking the café?\nAnswer: Alex Kim 12:34."))
        #expect(answer.hasSuffix("Question: What was the budget for the offsite?"))
    }

    @Test func askPieces() {
        // A tag with several times, a time past the hour, and a path that needs encoding.
        let odd = "Board (Q4)/2026-10-29 1630 Budget & plan #2"
        #expect(citationLinks("See [M1 1:02:03, 12:34].", sources: [odd]) == "See [1:02:03](Board%20%28Q4%29/2026-10-29%201630%20Budget%20%26%20plan%20%232#1:02:03), [12:34](Board%20%28Q4%29/2026-10-29%201630%20Budget%20%26%20plan%20%232#12:34).")
        // With more than one meeting in front of the model, a bare time is left alone: it could be in any of them.
        #expect(citationLinks("At [12:34].", sources: ["a/2026-10-29 1630 X", "b/2026-10-30 1630 Y"]) == "At [12:34].")
        #expect(citationLinks("Already [M1](x) a link.", sources: ["a/2026-10-29 1630 X"]) == "Already [M1](x) a link.")
        // A transcript that fits is given whole; one that doesn't, as the parts that share a word with the question.
        let turns = (0..<60).map { "**[\(clock(Double($0) * 60))] Alex:** " + ($0 == 40 ? "The zebra budget is nine thousand." : String(repeating: "filler ", count: 80).trimmed) }
        let whole = turns.joined(separator: "\n\n")
        #expect(transcriptFor(whole, question: "anything", tokens: 100_000) == (whole, true))
        let near = transcriptFor(whole, question: "What was the zebra budget?", tokens: 2_000)
        #expect(!near.whole && near.text == turns[39...41].joined(separator: "\n\n"))
        let start = transcriptFor(whole, question: "What happened?", tokens: 2_000)
        #expect(!start.whole && start.text.hasPrefix(turns[0]) && LocalModels.tokens(in: start.text) <= 2_000)
        #expect(questionWords("What did Priya say about the Café budget?") == ["priya", "cafe", "budget"])
    }

    /// A model's file is carried on from where an earlier download stopped, and only kept when it's
    /// the file that was expected.
    @Test func downloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
        let server = try await StandIn { request in
            guard let range = request.headers["range"], let from = Int(range.replacingOccurrences(of: "bytes=", with: "").dropLast()) else {
                return StandIn.Response(body: content)
            }
            return StandIn.Response(status: 206, headers: ["Content-Range": "bytes \(from)-\(content.count - 1)/\(content.count)"], body: content[from...])
        }
        func model(sha256: String) -> LocalModel {
            LocalModel(id: "test", title: "Test model", detail: "", file: "test.gguf", url: server.address + "/test.gguf", sha256: sha256,
                       bytes: Int64(content.count), baseMemory: 1, memoryPerThousandTokens: 0.1)
        }
        let good = model(sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
        let file = dir.appendingPathComponent("test.gguf"), part = file.appendingPathExtension("part")

        // The first third is here already: only the rest is asked for.
        try content[..<100_000].write(to: part)
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(try Data(contentsOf: file) == content && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == "bytes=100000-")
        // It's here now: nothing is fetched.
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(server.requests.count == 1)

        // From nothing, and a file that isn't the one expected is thrown away.
        try FileManager.default.removeItem(at: file)
        await #expect(throws: OatcakeError.self) { try await ModelDownload.fetch(model(sha256: String(repeating: "0", count: 64)), to: file) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.last?.headers["range"] == nil)
    }
}

private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

@Suite struct QuillTests {
    /// A tiny backup in Quill's shape: two meetings with the same title, one with a named voice, notes and a recording.
    @Test func importsBackup() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-quill-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let src = work.appendingPathComponent("backup"), root = work.appendingPathComponent("Meetings")
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        let audioDir = src.appendingPathComponent("meetings/1767268800000-\(a)")
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // A partial take sorts first by name; the finished one is still the one imported.
        try Data("partial".utf8).write(to: audioDir.appendingPathComponent("\(a)-1767268800.000000-combined.m4a"))
        try Data("combined".utf8).write(to: audioDir.appendingPathComponent("\(a)-FINAL-1767268800.000000-1767268870.000000-combined.m4a"))
        try Data("mic".utf8).write(to: audioDir.appendingPathComponent("\(a)-FINAL-mic.m4a"))
        let transcript = #"{"blocks":[{"from":1767268801000,"to":1767268802000,"text":"Morning.","source":"system","speaker_id":"S1"},{"from":1767268803000,"to":1767268804000,"text":"Hi Sam.","source":"mic","speaker_id":"S2"},{"from":1767268810000,"to":1767268811000,"text":"Who's that?","source":"system","speaker_id":"S3"}]}"#
        _ = try runCapturing("/usr/bin/sqlite3", [src.appendingPathComponent("quill.db").path, """
            CREATE TABLE Meeting (id TEXT, start DATETIME, "end" DATETIME, audio_transcript TEXT, title TEXT, folder TEXT,
                deleteDate DATETIME, hidden BOOLEAN, eventTitle TEXT, manualTitle TEXT);
            CREATE TABLE Note (id TEXT, meeting_id TEXT, title TEXT, body TEXT, createdAt DATETIME);
            CREATE TABLE ContactMeeting (contact_id TEXT, speaker_id TEXT, meeting_id TEXT, suggested_name TEXT);
            CREATE TABLE Contact (id TEXT, name TEXT);
            INSERT INTO Meeting VALUES ('\(a)', 1767268800000, 1767268870000, '\(transcript.replacingOccurrences(of: "'", with: "''"))', 'Planning', '1767268800000-\(a)', NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(b)', 1767355200000, NULL, '{"blocks":[{"from":1767355201000,"to":1767355202000,"text":"Hello.","source":"mic"}]}', 'Planning', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('33333333-3333-3333-3333-333333333333', 1767441600000, NULL, NULL, 'Deleted', NULL, 1767445200000, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('44444444-4444-4444-4444-444444444444', 1767441600000, NULL, NULL, 'Hidden', NULL, NULL, 1, NULL, NULL);
            INSERT INTO Note VALUES ('n1', '\(a)', 'Minutes', '## Plans &amp; dates' || char(10) || char(10) || '#### 2m' || char(10) || '- Ship it', 1);
            INSERT INTO Contact VALUES ('c1', 'Sam Lee');
            INSERT INTO ContactMeeting VALUES ('c1', 'S1', '\(a)', NULL);
            """])
        let zip = work.appendingPathComponent("QuillBackup.zip")
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])

        let first = try importQuill(zip, into: root, me: "Alex")
        // The deleted and the hidden meeting are left out altogether: not imported, skipped or unreadable.
        #expect(first.imported == 2 && first.skipped == 0 && first.unreadable == 0)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Quill").path) == ["Planning"])
        let series = root.appendingPathComponent("Quill/Planning")
        let folders = try fm.contentsOfDirectory(atPath: series.path).sorted()
        #expect(folders.count == 2)
        let meeting = series.appendingPathComponent(folders[0])
        #expect(readText(meeting.appendingPathComponent("transcript.md")) ==
                "**[00:01] Sam Lee:** Morning.\n\n**[00:03] Alex:** Hi Sam.\n\n**[00:10] Voice 1:** Who's that?\n")
        #expect(readText(meeting.appendingPathComponent("summary.md")) == "## Plans & dates\n\n- Ship it\n")
        #expect(readText(meeting.appendingPathComponent("audio.m4a")) == "combined")
        let meta = try JSONDecoder().decode(MeetingMeta.self, from: Data(contentsOf: meeting.appendingPathComponent("meeting.json")))
        #expect(meta.title == "Planning" && meta.source == "quill" && meta.participants == ["Sam Lee", "Alex"] && meta.endedAt != nil)
        // The meeting without a recording or notes still comes in, with just its transcript and meeting.json.
        #expect(try fm.contentsOfDirectory(atPath: series.appendingPathComponent(folders[1]).path).sorted() == ["meeting.json", "transcript.md"])

        let again = try importQuill(zip, into: root, me: "Alex")
        #expect(again.imported == 0 && again.skipped == 2)

        // With call audio not kept (Settings › Storage), the recording stays in the backup.
        let lean = work.appendingPathComponent("Lean")
        #expect(try importQuill(zip, into: lean, me: "Alex", keepAudio: false).imported == 2)
        #expect(try fm.contentsOfDirectory(atPath: lean.appendingPathComponent("Quill/Planning/\(folders[0])").path).sorted() == ["meeting.json", "summary.md", "transcript.md"])
    }

    /// What a real backup may hold that a tidy one doesn't: rows that belong to nothing, a transcript
    /// block that's malformed, several notes on one meeting, and a meeting that can't be written.
    @Test func survivesAnUntidyBackup() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-quill-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let src = work.appendingPathComponent("backup"), root = work.appendingPathComponent("Meetings")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let a = "aaaaaaaa-1111-1111-1111-111111111111", b = "bbbbbbbb-2222-2222-2222-222222222222", c = "cccccccc-3333-3333-3333-333333333333"
        // The second block has no text and the third isn't a block at all.
        let transcript = #"{"blocks":[{"from":1767268801000,"to":1767268802000,"text":"Morning.","source":"system","speaker_id":"S1"},{"from":1767268803000,"text":null},null,{"from":1767268805000,"text":"Shall we start?","source":"mic"}]}"#
        _ = try runCapturing("/usr/bin/sqlite3", [src.appendingPathComponent("quill.db").path, """
            CREATE TABLE Meeting (id TEXT, start DATETIME, "end" DATETIME, audio_transcript TEXT, title TEXT, folder TEXT,
                deleteDate DATETIME, hidden BOOLEAN, eventTitle TEXT, manualTitle TEXT);
            CREATE TABLE Note (id TEXT, meeting_id TEXT, title TEXT, body TEXT, createdAt DATETIME);
            CREATE TABLE ContactMeeting (contact_id TEXT, speaker_id TEXT, meeting_id TEXT, suggested_name TEXT);
            CREATE TABLE Contact (id TEXT, name TEXT);
            INSERT INTO Meeting VALUES ('\(a)', 1767268800000, 1767268870000, '\(transcript)', 'Review', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(b)', 1767355200000, NULL, '{"blocks":[{"from":1767355201000,"to":1767355202000,"text":"Hello.","source":"mic"}]}', '\(String(repeating: "x", count: 300))', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(c)', 1767441600000, NULL, '{"blocks":[{"from":1767441601000,"to":1767441602000,"text":"Right.","source":"mic"}]}', 'Retro', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('dddddddd-4444-4444-4444-444444444444', 1798761600000, NULL, NULL, 'Dentist', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Note VALUES ('n1', '\(a)', 'Minutes', '- **Decision:** ship Friday' || char(10) || '- **Owner:** Sam', 1);
            INSERT INTO Note VALUES ('n2', '\(a)', 'Follow-ups', 'Book the room.', 2);
            INSERT INTO Note VALUES ('n3', '\(a)', 'Empty', '', 3);
            INSERT INTO Note VALUES ('n4', NULL, 'Belongs to nothing', 'Lost.', 4);
            INSERT INTO Contact VALUES ('c1', 'Sam Lee');
            INSERT INTO ContactMeeting VALUES ('c1', 'S1', '\(a)', NULL);
            INSERT INTO ContactMeeting VALUES ('c1', NULL, '\(a)', NULL);
            INSERT INTO ContactMeeting VALUES ('c1', 'S9', NULL, NULL);
            """])
        let zip = work.appendingPathComponent("QuillBackup.zip")
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])

        // The meeting whose title is too long for a folder name is passed over; the one after it still comes in.
        // The row with nothing in it (no words, notes or recording) isn't a meeting, and isn't counted.
        let first = try importQuill(zip, into: root, me: "Alex")
        #expect(first.imported == 2 && first.skipped == 0 && first.unreadable == 1)
        let quill = root.appendingPathComponent("Quill")
        let folders = try fm.contentsOfDirectory(atPath: quill.path).sorted()
        #expect(folders.count == 2 && folders[0].hasSuffix("Review") && folders[1].hasSuffix("Retro"))
        // The blocks that are whole are kept.
        #expect(readText(quill.appendingPathComponent("\(folders[0])/transcript.md")) == "**[00:01] Sam Lee:** Morning.\n\n**[00:05] Alex:** Shall we start?\n")
        // Each note that has something in it under its title, at a level the meeting view keeps.
        let summary = readText(quill.appendingPathComponent("\(folders[0])/summary.md"))
        #expect(summary == "## Minutes\n\n- **Decision:** ship Friday\n- **Owner:** Sam\n\n## Follow-ups\n\nBook the room.\n")
        #expect(forReading(summary) == summary)
        // A lone note with something in it needs no heading, whatever empty ones sit beside it.
        #expect(quillSummary([(title: "Empty", body: " "), (title: "Minutes", body: "Shipped.")]) == "Shipped.\n")
        // Again: the two are already here, and the third is still passed over rather than stopping the import.
        let again = try importQuill(zip, into: root, me: "Alex")
        #expect(again.imported == 0 && again.skipped == 2 && again.unreadable == 1)

        // A .zip that isn't one, and one that isn't Quill's backup, are each said to be what they are.
        let broken = work.appendingPathComponent("Broken.zip")
        try Data("not a zip".utf8).write(to: broken)
        #expect(throws: OatcakeError("That .zip couldn’t be opened. It may be incomplete or damaged.")) { try importQuill(broken, into: root, me: "Alex") }
        let other = work.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: other.appendingPathComponent("readme.txt"))
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", other.path, work.appendingPathComponent("Other.zip").path])
        #expect(throws: OatcakeError("That .zip has no quill.db at its top level. Is it the backup as Quill made it?")) {
            try importQuill(work.appendingPathComponent("Other.zip"), into: root, me: "Alex")
        }
    }

    @Test func transcriptAndNotesAsWritten() {
        // Lines come out in the order they were said, whatever order the backup has them in, and ones
        // from before the meeting's start time keep their spacing rather than all landing on 00:00.
        let blocks = #"{"blocks":[{"from":70000,"to":71000,"text":"Third.","source":"system","speaker_id":"S2"},{"from":1000,"to":2000,"text":"First.","source":"system","speaker_id":"S1"},{"from":40000,"to":41000,"text":"Second.","source":"mic"}]}"#
        #expect(quillTranscript(blocks, start: 60000, me: "Alex", names: [:]).markdown == "**[00:00] Voice 1:** First.\n\n**[00:39] Alex:** Second.\n\n**[01:09] Voice 2:** Third.\n")
        // Quill's minute markers go and the paragraph break around them stays; a heading of your own is kept.
        #expect(quillSummary([(title: nil, body: "First point\n#### 2m\n\nSecond point\n#### 1h 2m\nThird\n\n### 5m\nFourth")]) == "First point\n\nSecond point\nThird\n\n### 5m\nFourth\n")
    }
}

@Suite struct GranolaImportTests {
    /// A note that can't be written (a title too long for a folder name) is passed over, and the ones after it still come in.
    @Test func carriesOnPastANoteItCannotWrite() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-granola-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let export = work.appendingPathComponent("export.csv"), root = work.appendingPathComponent("Meetings")
        try """
            document_id,document_title,document_created,summary,transcript,notes
            aaaaaaaa-1111-1111-1111-111111111111,Review,2026-01-01T12:00:00.000Z,Went well.,,
            bbbbbbbb-2222-2222-2222-222222222222,\(String(repeating: "x", count: 300)),2026-01-02T12:00:00.000Z,Too long.,,
            cccccccc-3333-3333-3333-333333333333,Retro,2026-01-03T12:00:00.000Z,Done.,,

            """.write(to: export, atomically: true, encoding: .utf8)
        let first = try importGranola(export, into: root)
        #expect(first.imported == 2 && first.unreadable == 1)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Granola").path).count == 2)
        let again = try importGranola(export, into: root)
        #expect(again.imported == 0 && again.skipped == 2 && again.unreadable == 1)
    }
}
