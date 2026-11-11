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

/// What you've set on a Who's who screen, kept by the app so looking at something else and coming
/// back loses nothing.
struct ReviewDraft: Equatable {
    struct Voice: Equatable {
        var name: String
        /// The name was picked from the calendar invite.
        var fromInvite = false
        var mixed = false
        /// Merged into another voice (`me` for your microphone).
        var into: String?
    }
    var title: String
    /// Where the meeting will be saved, relative to the Meetings folder.
    var folder: String
    var voices: [String: Voice]
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
    /// The time, moved on every half minute: what Upcoming's countdowns are worked out from.
    var now = Date()
    var calendarFetching = false
    var pending: [Recording] = []
    var todoMeetings: [MeetingTodos] = []
    var progress: [String: JobProgress] = [:]
    /// Meetings whose summary is being written now, and why the last attempt failed, by path.
    var summarising = Set<String>()
    var summaryErrors: [String: String] = [:]
    /// Where each meeting being summarised lives now: it can be renamed or moved while the model writes.
    private var summaryJobs: [UUID: String] = [:]
    var reviewDrafts: [String: ReviewDraft] = [:]
    var live: Recording?
    /// The call being recorded, as it's heard: lines from the live helper, and what the helper is doing.
    var liveLines: [LiveTranscriptLine] = []
    var liveStatus = ""
    /// Bumped by ⌘F and ⌥⌘F: the open meeting shows Find, the meeting list focuses its search.
    var findRequest = 0
    var searchRequest = 0
    /// File › New Folder: the sidebar asks for the new top-level folder's name. It waits here until the
    /// sidebar takes it, which is after the window has opened if it was closed.
    var wantsNewFolder = false
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
    /// How far each language model's download has got (0 to 1) while one is under way, and why the
    /// last one stopped, by model.
    var modelDownloads: [String: Double] = [:]
    var modelDownloadErrors: [String: String] = [:]
    /// Bumps when a model's file arrives or is removed, so Settings looks at the disk again.
    var modelsVersion = 0
    private var modelDownloadTasks: [String: Task<Void, Error>] = [:]

    /// Recorders running now, by recording ID.
    private var active: [String: Recording] = [:]
    private var analysing = Set<String>()
    /// The analysis helper running for each recording, and the work around it (which goes on to
    /// suggest names), so discarding a recording stops both.
    private var helpers: [String: Process] = [:]
    private var analyses: [String: Task<Void, Never>] = [:]
    private var autoStarted = Set<String>()
    private var liveHelper: Process?
    /// The recording whose live transcript helper is running or on its way up. A second helper for the
    /// same recording would say every line again.
    private var liveTranscriptFor: String?
    /// When a calling app started using the microphone, whether recording has been offered for that
    /// call, whether the recording in progress has had a calling app on the microphone, and since
    /// when it has had neither that nor any call audio.
    private var callSince: Date?
    private var callOffered = false
    private var callSeen = false
    private var callOverSince: Date?
    private let menuBar = MenuBarItem()
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
        Secrets.forgetRetired()
        SpeechModels.removeOldModels()
        // A language model left running by a copy of Oatcake that didn't get to stop it.
        ModelServer.stopLeftover()
        try? FileManager.default.removeItem(at: Paths.data.appendingPathComponent("Chromium"))

        resumeRecordings()
        watchMeetings()
        // The first load happens before the window shows, so it opens on your last meeting rather
        // than on whatever the sidebar selects by itself.
        tree = meetings.tree()
        todoMeetings = meetings.allTodos()
        pending = Recordings.list().filter { $0.state == .recorded || $0.state == .processed }
        openLastMeeting()
        refresh()
        // An address set in an earlier session counts as already fetched, so this only fetches if stale.
        calendarUrlFetched = calendarAddress
        refreshCalendar()
        checkReminders()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refreshCalendar() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.now = Date()
                self.checkReminders()
                self.updateMenuBar()
                // The language model gives its memory back after ten minutes with nothing to write.
                await ModelServer.shared.stopIfIdle(for: 600)
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.checkCall() } })
        menuBar.stop = { [weak self] in Task { @MainActor in await self?.stopLive() } }
        menuBar.open = { [weak self] in self?.showWindow() }
        menuBar.record = { [weak self] in self?.newRecording() }
        menuBar.openEvent = { [weak self] event in self?.openEvent(event) }
        updateMenuBar()
        updater.start(autoCheck: { [weak self] in self?.config.updateCheck ?? false },
                      busy: { [weak self] in self?.busyReason })
    }

    // MARK: - Meetings folder

    func refresh() {
        let meetings = meetings
        Task {
            let (tree, pending, todos) = await Task.detached {
                (meetings.tree(), Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, meetings.allTodos())
            }.value
            // Without animation: the sidebar's outline animates rows in when a section (Needs review)
            // appears, and leaves a stray copy of an expanded folder's selected row behind.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                self.tree = tree
                self.pending = pending
                self.todoMeetings = todos
                self.diskVersion += 1
            }
            // Recordings waiting to be processed start straight away, in the background.
            for rec in pending where rec.state == .recorded && !autoStarted.contains(rec.id) {
                autoStarted.insert(rec.id)
                analyse(rec.id)
            }
            updateBadge()
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

    /// Opens a meeting picked in the middle column, which stays as it is (all meetings, a folder, or
    /// search results) rather than switching to the meeting's own folder.
    func selectMeeting(_ path: String, jump: Jump? = nil) {
        guard tree?.find(path)?.kind == .meeting else { return }
        selection = .meeting(path, jump: jump)
        UserDefaults.standard.set(path, forKey: "lastMeeting")
    }

    /// ⌥⌘F: the meeting list's search box, bringing the list back first if another screen is showing.
    func searchMeetings() {
        showWindow()
        switch selection {
        case .meeting, .folder, nil: break
        default: openFolder(folder)
        }
        DispatchQueue.main.async { self.searchRequest += 1 }
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
        // A summary on its way follows the meeting to where it is now.
        summarising = Set(summarising.map(remap))
        summaryJobs = summaryJobs.mapValues(remap)
        summaryErrors = Dictionary(summaryErrors.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
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

    /// A meeting's new title, in meeting.json and in its folder's name.
    func retitle(_ path: String, to title: String) {
        guard !title.trimmed.isEmpty else { return }
        attempt { moved(from: path, to: try meetings.retitle(path, to: title)) }
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
        // A control that sets what it already shows (a picker redrawn, a field losing focus) changes nothing.
        guard saved != config else { return }
        config = saved
        try? saved.save()
        for rec in active.values { try? Recordings.setMic(rec.dir, uid: saved.mic?.uid) }
        // The live transcript follows its switch straight away, mid-call too.
        if let live {
            if !saved.liveTranscript { stopLiveTranscript() } else if liveHelper == nil { startLiveTranscript(live) }
        }
        updateMenuBar()
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
            updateMenuBar()
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
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
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

    /// New recording (⌘N, the sidebar button, the menu bar): the screen to start one, or the call already being recorded.
    func newRecording(_ event: CalendarEvent? = nil) {
        showWindow()
        selection = live != nil ? .live : .new(event)
    }

    /// A recording started straight from a calendar event carries the event and who else is invited.
    private func startOptions(_ event: CalendarEvent) -> Recordings.StartOptions {
        .init(eventId: event.id, attendees: otherAttendees(event, myName: config.myName).map(attendeeName))
    }

    /// The link to the call being recorded, when it was started from a calendar event that has one.
    var liveCallLink: URL? {
        guard let id = live?.eventId, let link = calendar?.events.first(where: { $0.id == id })?.callLink else { return nil }
        return URL(string: link)
    }

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
        callSeen = false
        callOverSince = nil
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let live = self.live else { return }
                self.status = Recordings.status(live)
                self.updateMenuBar()
            }
        }
        startLiveTranscript(rec)
        updateMenuBar()
        // The language model is fetched while the first call is recorded, to be there when it ends.
        if let chosenModel, !LocalModels.isDownloaded(chosenModel) { downloadModel(chosenModel) }
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
        stopLiveTranscript()
        live = nil
        statusTimer?.invalidate()
        statusTimer = nil
        status = RecorderStatus(state: .starting)
        updateMenuBar()
    }

    func confirmStop() {
        confirmation = Confirmation(
            title: "Stop recording?",
            text: "Oatcake will transcribe the call and ask you to check who’s who. You can’t add more to this recording afterwards.",
            ok: "Stop recording", cancel: "Keep recording") { [self] in await stopLive() }
    }

    /// Stops the call being recorded and starts processing it. If you're on its notes you go to its
    /// progress; anywhere else, you stay there.
    func stopLive() async {
        guard let rec = live else { return }
        let watching = selection == .live
        saveLiveNotes(rec.id)
        await stopRecorder(rec)
        endLive()
        progress[rec.id] = JobProgress(step: "Starting")
        if watching || selection == .live { selection = .job(rec.id) }
        refresh()
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

    /// Never leave the recorder (or the language model) running behind a closed app.
    func stopAllRecorders() {
        if let live { saveLiveNotes(live.id) }
        stopLiveTranscript()
        for rec in active.values { Recordings.stop(rec) }
        ModelServer.stopLeftover()
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

    // MARK: - Calls

    /// Every couple of seconds: is a calling app using the microphone? A call that starts while
    /// nothing is being recorded gets an offer to record it. A recording that has had a calling
    /// app on the microphone stops once that app has let go and the call audio has been quiet for a
    /// quarter of a minute; music still playing, or a call you're only muted on, keeps it going.
    private func checkCall() {
        guard config.callNotice || (config.autoStop && live != nil) else { return }
        let apps = CallDetector.appsOnCall()
        let now = Date()
        guard !apps.isEmpty else {
            callSince = nil
            guard live != nil, callSeen, config.autoStop, status.state == .recording, (status.systemLevel ?? 0) < 0.001 else {
                callOverSince = nil
                return
            }
            callOverSince = callOverSince ?? now
            if now.timeIntervalSince(callOverSince!) >= 15 { callEnded() }
            return
        }
        callOverSince = nil
        if callSince == nil {
            callSince = now
            callOffered = false
        }
        if live != nil {
            callSeen = true
        } else if config.callNotice, !callOffered, now.timeIntervalSince(callSince!) >= 4 {
            callOffered = true
            Reminders.offerRecording(app: apps[0], event: currentEvent)
        }
    }

    private func callEnded() {
        guard let rec = live else { return }
        callOverSince = nil
        Task {
            await stopLive()
            Reminders.stopped(rec.title)
            toast("The call ended, so recording stopped")
        }
    }

    /// The calendar event happening now (or starting within ten minutes), if any.
    var currentEvent: CalendarEvent? {
        let now = Date()
        return calendar?.events.first { !$0.allDay && $0.startDate.addingTimeInterval(-600) <= now && $0.endDate > now }
    }

    /// From the "On a call?" notification: record it, under the calendar event happening now if there is one.
    func recordCall() {
        showWindow()
        guard active.isEmpty else { return selection = .live }
        do {
            if let event = currentEvent {
                let folder = try meetings.folderForEvent(title: event.title, recurring: event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
            } else {
                try startRecording(title: "Call", folder: "", options: .init())
            }
        } catch {
            toast(error.localizedDescription)
        }
    }

    // MARK: - Live transcript

    private func startLiveTranscript(_ rec: Recording) {
        // Asked for again while the helper is still on its way up (settings saved just after the call
        // started, say): one is enough.
        guard liveTranscriptFor != rec.id else { return }
        liveLines = []
        liveStatus = ""
        guard config.liveTranscript, liveHelper == nil else { return }
        liveTranscriptFor = rec.id
        liveStatus = "Starting"
        Task {
            _ = try? await ChildProcess.run(Bundle.main.executableURL!, ["--live", rec.dir.path], onStart: { process in
                Task { @MainActor in
                    // The call may have ended (or the switch been turned off) before the helper got going.
                    if self.live?.id == rec.id, self.liveTranscriptFor == rec.id, self.config.liveTranscript { self.liveHelper = process } else { process.terminate() }
                }
            }, onLine: { line in
                guard let event = try? JSONDecoder().decode(LiveEvent.self, from: Data(line.utf8)) else { return }
                Task { @MainActor in
                    guard self.live?.id == rec.id else { return }
                    if let line = event.line { self.liveLines.append(line) }
                    if let status = event.status { self.liveStatus = status }
                    if let error = event.error { self.liveStatus = "The live transcript stopped: \(error)" }
                }
            })
        }
    }

    private func stopLiveTranscript() {
        liveHelper?.terminate()
        liveHelper = nil
        liveTranscriptFor = nil
    }

    // MARK: - Menu bar

    /// The menu bar shows the call being recorded (with Stop) or, with a calendar connected and the
    /// setting on, the time until the next call.
    var showsNextCallInMenuBar: Bool { config.menuBarNextCall && calendar != nil }

    func updateMenuBar() {
        if let live {
            menuBar.show(.recording(title: live.title, elapsed: status.state == .recording ? status.elapsed ?? 0 : nil))
        } else if showsNextCallInMenuBar {
            let now = Date()
            menuBar.show(.upcoming((calendar?.events ?? []).filter { !$0.allDay && $0.endDate > now }))
        } else {
            menuBar.hide()
        }
    }

    // MARK: - Processing

    func analyse(_ id: String) {
        guard let rec = Recordings.get(id), !analysing.contains(id) else { return }
        analysing.insert(id)
        progress[id] = JobProgress(step: progress[id]?.step ?? "Starting")
        analyses[id] = Task {
            // Steps arrive as they happen; the outcome is read from the full output once it exits.
            let result = try? await ChildProcess.run(Bundle.main.executableURL!, ["--analyse", rec.dir.path], onStart: { process in
                Task { @MainActor in self.helpers[id] = process }
            }, onLine: { line in
                guard let p = try? JSONDecoder().decode(AnalysisProgress.self, from: Data(line.utf8)), p.step != nil else { return }
                Task { @MainActor in self.apply(id, p) }
            })
            helpers.removeValue(forKey: id)
            var outcome = (result?.stdout ?? "").split(separator: "\n").reversed()
                .compactMap { try? JSONDecoder().decode(AnalysisProgress.self, from: Data($0.utf8)) }
                .first { $0.done == true || $0.error != nil }
            if outcome == nil {
                if result?.status == 0, FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent("analysis.json").path) {
                    outcome = AnalysisProgress(done: true)
                } else {
                    let detail = result.map { $0.stderr.trimmed.isEmpty ? "" : ": " + String($0.stderr.trimmed.suffix(300)) } ?? ""
                    outcome = AnalysisProgress(error: "Analysis stopped (code \(result?.status ?? -1))\(detail)")
                }
            }
            // Step 5, here rather than in the helper: the language model is the app's to run. A model
            // that's still downloading isn't waited for; the names can be typed.
            if outcome?.done == true, Recordings.get(id) != nil, !Task.isCancelled, hasUnnamedVoices(rec.dir) {
                progress[id] = JobProgress(step: analysisSteps[4])
                if let chosenModel, !LocalModels.isDownloaded(chosenModel) { downloadModel(chosenModel) }
                await suggestNames(rec.dir, config: config)
            }
            analysing.remove(id)
            analyses.removeValue(forKey: id)
            // Discarded while it ran: nothing to report.
            guard Recordings.get(id) != nil else {
                progress.removeValue(forKey: id)
                return
            }
            if let outcome { apply(id, outcome) }
        }
    }

    /// Whether a recording is still being worked on (its review waits until it isn't).
    func isAnalysing(_ id: String) -> Bool { analysing.contains(id) }

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
            // A helper still analysing it would write its transcript and clips back after the folder had gone.
            helpers.removeValue(forKey: rec.id)?.terminate()
            analyses.removeValue(forKey: rec.id)?.cancel()
            try Recordings.discard(rec.id)
            reviewDrafts.removeValue(forKey: rec.id)
            progress.removeValue(forKey: rec.id)
            openFolder(folder)
            toast("Recording discarded")
            refresh()
        }
    }

    /// Saves a reviewed recording as a meeting and starts writing its summary. Returns the meeting's path.
    func saveRecording(_ rec: Recording, decisions: [String: Decision], folder: String, title: String) throws -> String {
        let path = try saveMeeting(config, rec, decisions: decisions, folder: folder, title: title)
        reviewDrafts.removeValue(forKey: rec.id)
        writeSummary(path)
        return path
    }

    /// Writes a saved meeting's summary and to-dos in the background: after every save, and from
    /// Write summary when an earlier attempt couldn't reach the model.
    func writeSummary(_ path: String) {
        guard !summarising.contains(path) else { return }
        summarising.insert(path)
        summaryErrors.removeValue(forKey: path)
        let job = UUID()
        summaryJobs[job] = path
        let config = config
        Task {
            do {
                try await ensureModel()
                let draft = try await OatcakeCore.draftSummary(config, meeting: path)
                try OatcakeCore.writeSummary(draft, config: config, meeting: summaryJobs[job] ?? path)
            } catch {
                summaryErrors[summaryJobs[job] ?? path] = error.localizedDescription
            }
            summarising.remove(summaryJobs[job] ?? path)
            summaryJobs.removeValue(forKey: job)
            refresh()
        }
    }

    // MARK: - Language model

    /// The model chosen in Settings, when it's one Oatcake downloads and runs itself.
    var chosenModel: LocalModel? { LocalModels.find(config.llm.model) }

    /// "Downloading the language model: 42% of 5.0 GB", while the chosen one is on its way.
    var modelDownloadStatus: String? {
        guard let chosenModel, let fraction = modelDownloads[chosenModel.id] else { return nil }
        return "Downloading the language model: \(Int(fraction * 100))% of \(chosenModel.downloadSize)"
    }

    /// Starts downloading a model, or joins the download already under way.
    @discardableResult
    func downloadModel(_ model: LocalModel) -> Task<Void, Error> {
        if let task = modelDownloadTasks[model.id] { return task }
        modelDownloadErrors.removeValue(forKey: model.id)
        modelDownloads[model.id] = 0
        let task = Task {
            defer {
                modelDownloadTasks.removeValue(forKey: model.id)
                modelDownloads.removeValue(forKey: model.id)
                modelsVersion += 1
            }
            do {
                try await ModelDownload.fetch(model) { fraction in
                    Task { @MainActor in
                        if self.modelDownloadTasks[model.id] != nil { self.modelDownloads[model.id] = fraction }
                    }
                }
            } catch {
                if !isCancellation(error) { modelDownloadErrors[model.id] = error.localizedDescription }
                throw error
            }
        }
        modelDownloadTasks[model.id] = task
        return task
    }

    func stopModelDownload(_ model: LocalModel) { modelDownloadTasks[model.id]?.cancel() }

    /// Deletes a model's file, stopping its download or the model itself first.
    func removeModel(_ model: LocalModel) {
        let download = modelDownloadTasks[model.id]
        download?.cancel()
        Task {
            _ = try? await download?.value
            await ModelServer.shared.stop()
            LocalModels.remove(model)
            modelsVersion += 1
        }
    }

    /// Waits for the chosen model to be on this Mac, downloading it if it isn't. A server of your
    /// own needs nothing.
    func ensureModel() async throws {
        guard let chosenModel, !LocalModels.isDownloaded(chosenModel) else { return }
        let download = downloadModel(chosenModel)
        // Looked at again every so often, so that whatever is waiting (a question, say) can be
        // stopped without stopping the download.
        while modelDownloadTasks[chosenModel.id] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
        }
        do {
            try await download.value
        } catch where isCancellation(error) {
            // The download was stopped (in Settings), not what was waiting for it.
            throw OatcakeError(modelNotDownloadedMessage)
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
            return Job(rec: rec, status: p?.error != nil ? .failed : rec.state == .processed && !analysing.contains(rec.id) ? .review : .processing,
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
        if !summarising.isEmpty { return "Oatcake is writing a summary. Try again in a moment." }
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

    static let callCategory = "call-noticed"
    static let recordAction = "record"

    static func register() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: startAction, title: "Open call and start note taking", options: [.foreground])
        let record = UNNotificationAction(identifier: recordAction, title: "Start recording", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: callCategory, actions: [record], intentIdentifiers: [])])
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// A calling app has started using the microphone and nothing is being recorded.
    static func offerRecording(app: String, event: CalendarEvent?) {
        let content = UNMutableNotificationContent()
        content.title = "On a call?"
        content.body = "\(app) is using your microphone\(event.map { " (\($0.title))" } ?? ""). Oatcake isn’t recording."
        content.categoryIdentifier = callCategory
        content.sound = .default
        post(content, id: "call-noticed")
    }

    /// A recording stopped by itself because its call ended.
    static func stopped(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The call ended, so Oatcake stopped recording “\(title)” and is transcribing it."
        post(content, id: "call-ended")
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
/// following a link in an answer doesn't lose it. Each question is asked about the meeting that's open.
@MainActor @Observable
final class AskChat {
    var turns: [AskTurn] = []
    var open = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var running: AskTurn? { turns.first(where: \.running) }

    func send(_ question: String, meeting: String, app: AppModel) {
        let history = turns.compactMap { turn in turn.answer.map { AskExchange(question: turn.question, answer: $0) } }
        let turn = AskTurn(question: question)
        turns.append(turn)
        open = true
        let config = app.config
        tasks[turn.id] = Task {
            do {
                // The first question may find the model still on its way.
                let waiting = Task {
                    while !Task.isCancelled {
                        if let status = app.modelDownloadStatus { update(turn.id) { $0.step = status } }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                defer { waiting.cancel() }
                try await app.ensureModel()
                waiting.cancel()
                let answer = try await OatcakeCore.ask(config, meeting: meeting, question: question, history: history) { step in
                    Task { @MainActor in self.update(turn.id) { $0.step = step } }
                }
                update(turn.id) { $0.answer = answer }
            } catch {
                let message = error.localizedDescription
                update(turn.id) { if Task.isCancelled || isCancellation(error) { $0.stopped = true } else { $0.error = message } }
            }
            tasks.removeValue(forKey: turn.id)
        }
    }

    func cancel() {
        if let running { tasks[running.id]?.cancel() }
    }

    func newChat() {
        turns = []
        open = true
    }

    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }
}
