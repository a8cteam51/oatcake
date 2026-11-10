// The app's state and everything the windows ask for: the Meetings folder, recordings and their
// processing, the calendar and call reminders, Ask, and updates.

import AppKit
import OatcakeCore
import SwiftUI
import UserNotifications

/// What the detail pane shows.
enum Selection: Equatable {
    /// A meeting, optionally opened on a tab at a transcript time (the nonce makes a repeat jump count).
    case meeting(String, jump: Jump? = nil)
    case todos
    case folder(String)
    case new(CalendarEvent?, key: UUID = UUID())
    case live
    case job(String)
}

struct Jump: Equatable {
    var tab: MeetingTab
    var stamp: String?
    var nonce = UUID()
}

enum MeetingTab: String, CaseIterable { case summary, transcript, notes }

struct JobProgress: Equatable {
    var step: String
    var fraction: Double?
    var error: String?
}

/// "Stop recording?" and the like: a question with a destructive answer.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var ok: String
    var cancel: String
    var action: () async throws -> Void
}

/// A line typed during a call.
struct LiveLine: Identifiable, Equatable {
    let id = UUID()
    /// Seconds in when typing started; nil until then, and always for prep notes.
    var at: Double?
    var prep: Bool
    var text: String
}

@MainActor @Observable
final class AppModel {
    var config: Config
    private(set) var meetings: Meetings
    var tree: TreeNode?
    /// Bumps on every change on disk, so open meetings re-read their files.
    var diskVersion = 0
    /// nil when no calendar address is set.
    var calendar: CalendarCache?
    var calendarFetching = false
    var pending: [Recording] = []
    var todoMeetings: [MeetingTodos] = []
    var progress: [String: JobProgress] = [:]
    /// What saving a reviewed recording is doing, by recording.
    var saveStep: [String: String] = [:]
    var live: Recording?
    var status = RecorderStatus(state: .starting)
    var selection: Selection?
    /// The folder the middle column lists.
    var folder = ""
    var confirmation: Confirmation?
    var toastText: String?
    let updater = Updater()
    let ask = AskChat()
    /// Notes typed during each call, kept here so leaving the live view and coming back keeps them.
    var liveNotes: [String: [LiveLine]] = [:]
    var pendingEvent: CalendarEvent?

    /// Recorders running now, by recording ID.
    private var active: [String: Recording] = [:]
    private var analysing = Set<String>()
    private var autoStarted = Set<String>()
    private var saving = 0
    private var watcher: FolderWatcher?
    private var timers: [Timer] = []
    private var statusTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var calendarFetch: (url: String, task: Task<CalendarCache, Never>)?
    private var calendarUrlFetched = ""
    private var reminded = Set<String>()
    private var notesSaveTask: Task<Void, Never>?
    var openMainWindow: (() -> Void)?

    init() {
        let config = Config.load()
        self.config = config
        meetings = Meetings(root: config.meetingsRoot)
    }

    func start() {
        // Left by the Electron version: its secrets move into the Keychain, its speech models and
        // Chromium caches go.
        Secrets.migrateFromElectron()
        SpeechModels.removeOldModels()
        try? FileManager.default.removeItem(at: Paths.data.appendingPathComponent("Chromium"))

        resumeRecordings()
        watchMeetings()
        refresh(openLast: true)
        // An address set in an earlier session counts as already fetched, so this only fetches if stale.
        calendarUrlFetched = calendarAddress
        refreshCalendar()
        checkReminders()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refreshCalendar() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in self.checkReminders() } })
        updater.start(autoCheck: { [weak self] in self?.config.updateCheck ?? false },
                      busy: { [weak self] in self?.busyReason })
    }

    // MARK: - Meetings folder

    func refresh(openLast: Bool = false) {
        let meetings = meetings
        Task {
            let (tree, pending, todos) = await Task.detached {
                (meetings.tree(), Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, meetings.allTodos())
            }.value
            self.tree = tree
            self.pending = pending
            self.todoMeetings = todos
            self.diskVersion += 1
            // Recordings waiting to be processed start straight away, in the background.
            for rec in pending where rec.state == .recorded && !autoStarted.contains(rec.id) {
                autoStarted.insert(rec.id)
                analyse(rec.id)
            }
            updateBadge()
            if openLast { openLastMeeting() }
        }
    }

    /// Opens the meeting you were last reading, or on first run the most recent one.
    private func openLastMeeting() {
        guard selection == nil, let tree else { return }
        if let last = UserDefaults.standard.string(forKey: "lastMeeting"), tree.find(last)?.kind == .meeting {
            return openMeeting(last)
        }
        if let newest = tree.allMeetings.max(by: { (meetingDate($0) ?? .distantPast) < (meetingDate($1) ?? .distantPast) }) {
            openMeeting(newest.path)
        }
    }

    // Keep the sidebar in step with Finder.
    private func watchMeetings() {
        try? FileManager.default.createDirectory(at: meetings.root, withIntermediateDirectories: true)
        watcher = FolderWatcher(meetings.root) { [weak self] in self?.refresh() }
    }

    func openMeeting(_ path: String, jump: Jump? = nil) {
        guard tree?.find(path)?.kind == .meeting else { return }
        folder = parentOf(path)
        selection = .meeting(path, jump: jump)
        UserDefaults.standard.set(path, forKey: "lastMeeting")
    }

    func openFolder(_ path: String) {
        folder = path
        if let first = listedIn(tree?.find(path)).first {
            selection = .meeting(first.path)
            UserDefaults.standard.set(first.path, forKey: "lastMeeting")
        } else {
            selection = .folder(path)
        }
    }

    /// A folder or meeting now lives at `to` (renamed or moved).
    func moved(from: String, to: String) {
        let remap = { (p: String) in p == from ? to : p.hasPrefix(from + "/") ? to + p.dropFirst(from.count) : p }
        folder = remap(folder)
        switch selection {
        case .meeting(let p, let jump): selection = .meeting(remap(p), jump: jump)
        case .folder(let p): selection = .folder(remap(p))
        default: break
        }
        refresh()
    }

    func rename(_ path: String, to name: String) {
        guard !name.trimmed.isEmpty, name.trimmed != baseName(path) else { return }
        attempt { moved(from: path, to: try meetings.rename(path, to: name)) }
    }

    func move(_ path: String, into target: String) {
        guard path != target, !target.hasPrefix(path + "/"), parentOf(path) != target else { return }
        attempt {
            moved(from: path, to: try meetings.move(path, into: target))
            toast("Moved to \(folderPath(target))")
        }
    }

    @discardableResult
    func createFolder(in parent: String, named name: String) -> String? {
        var made: String?
        attempt { made = try meetings.createFolder(in: parent, named: name) }
        refresh()
        return made
    }

    func trash(_ node: TreeNode) {
        attempt {
            try meetings.trash(node.path)
            toast("Moved “\(node.kind == .meeting ? meetingTitle(node) : node.name)” to the Trash")
        }
        refresh()
    }

    func reveal(_ path: String) {
        if let url = try? resolveInside(meetings.root, path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func readMeeting(_ path: String) throws -> MeetingFiles { try meetings.read(path) }

    func writeMeetingFile(_ path: String, _ file: MeetingFile, _ content: String) throws {
        try meetings.write(path, file, content)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { toast(error.localizedDescription) }
    }

    func toast(_ text: String) {
        withAnimation { toastText = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { withAnimation { toastText = nil } }
        }
    }

    // MARK: - Settings

    func saveConfig(_ new: Config) {
        // The Meetings folder only changes through the folder picker.
        var saved = new
        saved.outputDir = config.outputDir
        config = saved
        try? saved.save()
        for rec in active.values { try? Recordings.setMic(rec.dir, uid: saved.mic?.uid) }
    }

    /// Saves the microphone choice and switches any running recording to it.
    func setMic(_ mic: MicChoice?) {
        var c = config
        c.mic = mic
        saveConfig(c)
    }

    func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.outputDir = url.path
        try? config.save()
        meetings = Meetings(root: url)
        watchMeetings()
        refresh()
    }

    /// Settings › Import from Granola: pick the export, import it, and show the new meetings.
    func importGranolaExport() async throws -> GranolaImport? {
        let panel = NSOpenPanel()
        panel.title = "Import from Granola"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.zip, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let root = meetings.root
        let result = try await Task.detached { try importGranola(url, into: root) }.value
        refresh()
        return result
    }

    func setSecret(_ name: SecretName, _ value: String) {
        let before = Secrets.get(name)
        attempt { try Secrets.set(name, value) }
        if name == .calendar, Secrets.get(.calendar) != before { calendarChanged() }
    }

    // MARK: - Calendar

    /// The calendar's private iCal address. "" = no calendar.
    private var calendarAddress: String { Secrets.get(.calendar).trimmed }

    /// Fetched at most once an hour (checked every 5 minutes, so a Mac that slept catches up),
    /// straight away when its address changes, and whenever the refresh button is pressed.
    func refreshCalendar(force: Bool = false) {
        let url = calendarAddress
        guard !url.isEmpty else {
            calendar = nil
            return
        }
        // Joins a fetch already running for this address.
        if calendarFetch?.url == url { return }
        let cached = CalendarCache.load()
        if calendar == nil { calendar = cached }
        if !force, url == calendarUrlFetched, !cached.isStale() { return }
        calendarFetching = true
        let task = Task { await fetchCalendar(url) }
        calendarFetch = (url, task)
        Task {
            let cache = await task.value
            // The address changed meanwhile: an older fetch's result is thrown away.
            guard calendarFetch?.url == url else { return }
            calendarFetch = nil
            calendarFetching = false
            calendarUrlFetched = url
            try? cache.save()
            calendar = cache
        }
    }

    /// A new (or no) calendar address: forget the old one's events and fetch the new one.
    private func calendarChanged() {
        calendarFetch = nil
        calendarFetching = false
        calendarUrlFetched = ""
        try? FileManager.default.removeItem(at: Paths.calendar)
        calendar = nil
        if !calendarAddress.isEmpty { refreshCalendar(force: true) }
    }

    // Call reminders: 5 minutes before each call, a notification whose button opens the call and
    // starts recording it. Clicking the notification itself opens New recording for the event.
    private func checkReminders() {
        guard config.callReminders, let calendar else { return }
        let now = Date()
        for event in calendar.events where !event.allDay && !reminded.contains(event.id) {
            let until = event.startDate.timeIntervalSince(now)
            // In the five minutes before it starts (or the first minute after, if the Mac was asleep).
            guard until <= 300, until >= -60 else { continue }
            reminded.insert(event.id)
            Reminders.show(event)
        }
    }

    /// Shows a reminder for the next timed event straight away, for checking notifications work.
    func testReminder() -> String? {
        guard let next = calendar?.events.first(where: { !$0.allDay && $0.endDate > Date() }) else { return nil }
        Reminders.show(next)
        return next.title
    }

    /// A clicked reminder: New recording for its event, unless a call is already being recorded.
    func openEvent(_ event: CalendarEvent) {
        showWindow()
        selection = live != nil ? .live : .new(event)
    }

    /// Opens the call's link, starts recording it, and brings Oatcake forward on the live notes.
    func startFromEvent(_ event: CalendarEvent) {
        if let link = event.callLink, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        // Already recording: go back to that recording rather than start a second.
        if active.isEmpty {
            do {
                let folder = try meetings.folderForEvent(title: event.title, recurring: event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: .init(eventId: event.id))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't start recording"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        // After the browser has opened the call, so Oatcake ends up in front for the notes.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            showWindow()
            selection = .live
        }
    }

    func showWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: - Recording

    func startRecording(title: String, folder: String, options: Recordings.StartOptions) throws {
        // One call at a time: a second recorder would capture the same audio.
        guard active.isEmpty else { throw OatcakeError("Oatcake is already recording a call. Stop it first.") }
        let rec = try Recordings.start(title: title, folder: folder, micUid: config.mic?.uid, options: options)
        active[rec.id] = rec
        goLive(rec)
    }

    private func goLive(_ rec: Recording) {
        live = rec
        status = RecorderStatus(state: .starting)
        selection = .live
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let live = self.live else { return }
                self.status = Recordings.status(live)
            }
        }
    }

    /// Recordings left from an earlier run: a recorder still going is picked up again; a dead one is finished off.
    private func resumeRecordings() {
        for rec in Recordings.list() where rec.state == .recording {
            if Recordings.isRunning(rec) {
                active[rec.id] = rec
                goLive(rec)
            } else {
                Recordings.finishInterrupted(rec)
            }
        }
    }

    /// Asks the recorder to finish and waits for its meta.json; keeps whatever audio it captured if it had already stopped.
    private func stopRecorder(_ rec: Recording) async {
        Recordings.stop(rec)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent("meta.json").path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        Recordings.finishInterrupted(rec)
        active.removeValue(forKey: rec.id)
    }

    private func endLive() {
        live = nil
        statusTimer?.invalidate()
        statusTimer = nil
        status = RecorderStatus(state: .starting)
    }

    func confirmStop() {
        confirmation = Confirmation(
            title: "Stop recording?",
            text: "Oatcake will transcribe the call and ask you to check who’s who. You can’t add more to this recording afterwards.",
            ok: "Stop recording", cancel: "Keep recording") { [self] in
                guard let rec = live else { return }
                saveLiveNotes(rec.id)
                await stopRecorder(rec)
                endLive()
                progress[rec.id] = JobProgress(step: "Starting")
                selection = .job(rec.id)
                refresh()
            }
    }

    /// Cancel before any audio arrived: stop the recorder and throw the recording away.
    func cancelRecording(hasNotes: Bool) {
        let cancel = { [self] in
            guard let rec = live else { return }
            await stopRecorder(rec)
            try Recordings.discard(rec.id)
            liveNotes.removeValue(forKey: rec.id)
            endLive()
            openFolder(folder)
            toast("Recording cancelled")
            refresh()
        }
        if !hasNotes {
            Task { do { try await cancel() } catch { toast(error.localizedDescription) } }
            return
        }
        confirmation = Confirmation(title: "Cancel this recording?",
                                    text: "Nothing has been recorded yet. The notes you’ve typed for it will be deleted.",
                                    ok: "Cancel recording", cancel: "Keep waiting", action: cancel)
    }

    /// Never leave the recorder running behind a closed app.
    func stopAllRecorders() {
        if let live { saveLiveNotes(live.id) }
        for rec in active.values { Recordings.stop(rec) }
    }

    var isRecording: Bool { !active.isEmpty }

    func saveLiveNotes(_ id: String) {
        guard let lines = liveNotes[id] else { return }
        try? Recordings.saveNotes(id, lines.filter { !$0.text.trimmed.isEmpty }.map { Note(at: $0.prep ? nil : $0.at ?? 0, text: $0.text.trimmed) })
    }

    /// Saved 600 ms after the last keystroke.
    func liveNotesChanged(_ id: String) {
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { saveLiveNotes(id) }
        }
    }

    // MARK: - Processing

    func analyse(_ id: String) {
        guard let rec = Recordings.get(id), !analysing.contains(id) else { return }
        analysing.insert(id)
        progress[id] = JobProgress(step: progress[id]?.step ?? "Starting")
        Task {
            // Steps arrive as they happen; the outcome is read from the full output once it exits.
            let result = try? await ChildProcess.run(Bundle.main.executableURL!, ["--analyse", rec.dir.path], onLine: { line in
                guard let p = try? JSONDecoder().decode(AnalysisProgress.self, from: Data(line.utf8)), p.step != nil else { return }
                Task { @MainActor in self.apply(id, p) }
            })
            analysing.remove(id)
            let outcome = (result?.stdout ?? "").split(separator: "\n").reversed()
                .compactMap { try? JSONDecoder().decode(AnalysisProgress.self, from: Data($0.utf8)) }
                .first { $0.done == true || $0.error != nil }
            if let outcome {
                apply(id, outcome)
            } else if result?.status == 0, FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent("analysis.json").path) {
                apply(id, AnalysisProgress(done: true))
            } else {
                let detail = result.map { $0.stderr.trimmed.isEmpty ? "" : ": " + String($0.stderr.trimmed.suffix(300)) } ?? ""
                apply(id, AnalysisProgress(error: "Analysis stopped (code \(result?.status ?? -1))\(detail)"))
            }
        }
    }

    private func apply(_ id: String, _ p: AnalysisProgress) {
        if p.done == true {
            progress.removeValue(forKey: id)
            refresh()
        } else if let error = p.error {
            progress[id] = JobProgress(step: progress[id]?.step ?? "Starting", error: error)
        } else if let step = p.step {
            progress[id] = JobProgress(step: step, fraction: p.fraction)
        }
        updateBadge()
    }

    func retry(_ rec: Recording) {
        progress[rec.id] = JobProgress(step: "Starting")
        analyse(rec.id)
    }

    func discard(_ rec: Recording) {
        confirmation = Confirmation(title: "Discard this recording?",
                                    text: "The audio, transcript and your notes will be deleted. This can’t be undone.",
                                    ok: "Discard", cancel: "Cancel") { [self] in
            try Recordings.discard(rec.id)
            progress.removeValue(forKey: rec.id)
            openFolder(folder)
            toast("Recording discarded")
            refresh()
        }
    }

    func saveRecording(_ rec: Recording, decisions: [String: Decision], folder: String) async throws -> String {
        saving += 1
        defer {
            saving -= 1
            saveStep.removeValue(forKey: rec.id)
        }
        saveStep[rec.id] = "Saving"
        let config = config
        return try await saveMeeting(config, rec, decisions: decisions, folder: folder) { step in
            Task { @MainActor in self.saveStep[rec.id] = step }
        }
    }

    // MARK: - Status

    struct Job: Identifiable {
        enum Status { case processing, review, failed }
        var rec: Recording
        var status: Status
        var step: Int
        var id: String { rec.id }
    }

    var jobs: [Job] {
        pending.sorted { $0.startedAt > $1.startedAt }.map { rec in
            let p = progress[rec.id]
            return Job(rec: rec, status: p?.error != nil ? .failed : rec.state == .processed ? .review : .processing,
                       step: stepNumber(p?.step ?? ""))
        }
    }

    /// The Dock badge counts what's waiting for you: recordings to review, or that failed.
    private func updateBadge() {
        let waiting = jobs.filter { $0.status != .processing }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    var todoCounts: (open: Int, overdue: Int) {
        let items = allTodoItems(todoMeetings)
        return (items.filter { !$0.todo.done }.count, items.filter { $0.isOverdue() }.count)
    }

    /// Why an update has to wait, if it does.
    var busyReason: String? {
        if !active.isEmpty { return "Oatcake is recording a call. Install the update after you stop." }
        if !analysing.isEmpty { return "Oatcake is analysing a call. Install the update when it's done." }
        if saving > 0 { return "Oatcake is saving a meeting. Try again in a moment." }
        return nil
    }
}

/// Step 1–5 for a progress message; downloads and model loading count as step 1.
func stepNumber(_ step: String) -> Int { max(1, (analysisSteps.firstIndex(of: step) ?? -1) + 1) }

/// Calls back (debounced) whenever anything under a folder changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(_ url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Call reminders through Notification Center, with one button.
enum Reminders {
    static let category = "call-reminder"
    static let startAction = "start"

    static func register() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: startAction, title: "Open call and start note taking", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: [])])
    }

    static func show(_ event: CalendarEvent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let minutes = Int((event.startDate.timeIntervalSinceNow / 60).rounded())
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = [minutes > 0 ? "In \(minutes) min" : "Starting now", "\(hhmm(event.startDate))–\(hhmm(event.endDate))",
                            event.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
            content.categoryIdentifier = category
            content.userInfo = ["event": (try? encodeJSON(event)) ?? ""]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }

    static func event(from response: UNNotificationResponse) -> CalendarEvent? {
        (response.notification.request.content.userInfo["event"] as? String)
            .flatMap { try? JSONDecoder().decode(CalendarEvent.self, from: Data($0.utf8)) }
    }
}

// MARK: - Ask

struct AskTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String?
    var error: String?
    var stopped = false
    var step: String?
    var startedAt = Date()
    var running: Bool { answer == nil && error == nil && !stopped }
}

/// One conversation for as long as the app is open. It carries on as you move between meetings, so
/// following a link in an answer doesn't lose it. Each question says which meeting is open.
@MainActor @Observable
final class AskChat {
    var sessionId: String?
    var turns: [AskTurn] = []
    var open = false
    private var requests: [UUID: AskRequest] = [:]

    var running: AskTurn? { turns.first(where: \.running) }

    func send(_ question: String, meeting: String, config: Config) {
        let turn = AskTurn(question: question)
        turns.append(turn)
        open = true
        let request = AskRequest()
        requests[turn.id] = request
        let session = sessionId
        let model = config.llm.provider == .claudeCode && !config.llm.claudeCode.model.isEmpty ? config.llm.claudeCode.model : nil
        Task {
            do {
                let answer = try await request.run(root: config.meetingsRoot, meeting: meeting, question: question, sessionId: session,
                                                   myName: config.myName, model: model) { step in
                    Task { @MainActor in self.update(turn.id) { $0.step = step } }
                }
                update(turn.id) { $0.answer = answer.answer }
                sessionId = answer.sessionId
            } catch {
                let message = error.localizedDescription
                update(turn.id) { if message == "Stopped." { $0.stopped = true } else { $0.error = message } }
            }
            requests.removeValue(forKey: turn.id)
        }
    }

    func cancel() {
        if let running { requests[running.id]?.cancel() }
    }

    func newChat() {
        turns = []
        sessionId = nil
        open = true
    }

    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }
}
