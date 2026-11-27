import OatcakeCore
import SwiftUI

private let topLevel = "\u{0}top"
private let newFolder = "\u{0}new"

private func eventWhen(_ e: CalendarEvent) -> String {
    let cal = Calendar.current
    let day = cal.isDateInToday(e.startDate) ? "Today" : cal.isDateInTomorrow(e.startDate) ? "Tomorrow" : weekdayName(e.startDate)
    return ["\(day) · \(timeOfDay(e.startDate))–\(timeOfDay(e.endDate))", e.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
}

struct NewRecordingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let event: CalendarEvent?

    @ViewState private var folder = topLevel
    @ViewState private var newName = ""
    @ViewState private var title = ""
    @ViewState private var summaryTemplate: String?
    @ViewState private var prep: [String] = []
    @ViewState private var prepDraft = ""
    @ViewState private var error = ""
    @ViewState private var starting = false
    @ViewState private var devices: [InputDevice]?
    @ViewState private var previous: (path: String, date: Date?, todo: String)?
    @ViewState private var ticked = Set<Int>()
    @ViewState private var ready = false
    private enum Field { case title, prep }
    @FocusState private var focus: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    if let event { Label(eventWhen(event), systemImage: "calendar").foregroundStyle(.secondary) }
                    PageTitle(text: "Record a call")
                }
                form
                if model.config.todosEnabled, !openTodos.isEmpty { previousTodos }
                prepNotes
                if !error.isEmpty { Notice(tone: .red) { Text(error) } }
                VStack(alignment: .leading, spacing: 10) {
                    // Said before it happens, where it's read before Start recording: the first recording
                    // brings a download of several gigabytes with it.
                    let _ = model.downloads.modelsVersion
                    if let chosen = model.downloads.chosenModel, !LocalModels.isDownloaded(chosen), model.downloads.modelDownloads[chosen.id] == nil {
                        Label("The language model that writes summaries (\(chosen.downloadSize)) starts downloading when you start recording.",
                              systemImage: "arrow.down.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let returnStarts = !starting && focus != .prep && !model.searching
                    HStack(spacing: 10) {
                        Button(action: start) {
                            Label(starting ? "Starting…" : "Start recording", systemImage: "circle.fill")
                                .padding(.horizontal, 6)
                        }
                        .help(returnStarts ? "Start recording (Return)" : "Start recording")
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .disabled(starting)
                        // Return starts the recording, except in the prep notes, where it adds the point typed,
                        // and while search is open over the window: Return is search's then.
                        .keyboardShortcut(returnStarts ? .defaultAction : nil)
                        if let link = event?.callLink, let url = URL(string: link) {
                            Button { NSWorkspace.shared.open(url) } label: { Label("Join the call", systemImage: "video") }
                                .controlSize(.large)
                                .help("Opens \(callApp(link) ?? "the call")")
                        }
                        // Escape too (but not while search is open: Escape closes that). Back to where you were before.
                        Button("Cancel") { model.cancelNewRecording() }.controlSize(.large).buttonStyle(.borderless)
                            .help(model.searching ? "Cancel" : "Cancel (Esc)")
                            .keyboardShortcut(model.searching ? nil : .cancelAction)
                    }
                    Text("Let the people on the call know you’re recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if !ready {
                setUp()
                focus = .title
            }
            await refreshDevices()
        }
        .task(id: candidateKey) { await loadPrevious() }
        // A point typed but not entered is kept too. Not once the call is being recorded, from here
        // or from a reminder: its prep notes have gone into the call, and saving them again would
        // bring them back for the next time.
        .onDisappear { if !starting && (event == nil || model.recording.live?.eventId != event?.id) { addPrep(prepDraft) } }
    }

    /**
     * Where a calendar event's recording goes: the folder named like the event (punctuation ignored),
     * or else where the latest meeting of the same name is. Failing both, a recurring event gets a new
     * folder named after it and a one-off goes at the top level. Without an event, the folder selected
     * in the sidebar. (Meetings.folderForEvent makes the same choice for a call started from a notification.)
     */
    private func setUp() {
        ready = true
        title = event?.title ?? ""
        prep = PrepNotes.load(event?.id)
        guard let event else {
            folder = model.folder.isEmpty ? topLevel : model.folder
            return
        }
        let tree = model.library.tree
        let earlier = tree.flatMap { latestMeeting(titled: event.title, in: $0) }
        summaryTemplate = model.config.summaryTemplate(named: earlier?.summaryTemplate)?.name
        if let tree, let match = matchingFolder(event.title, in: tree) {
            folder = match
        } else if let earlier {
            let parent = parentOf(earlier.path)
            folder = parent.isEmpty ? topLevel : parent
        } else if event.seriesId != nil {
            folder = newFolder
            // Folder names can't contain "/" or ":" ("John & Jane 1:1" becomes "John & Jane 1-1").
            newName = event.title.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        }
    }

    private func refreshDevices() async {
        devices = (try? await Recordings.listInputs()) ?? []
    }

    private var folderName: String {
        folder == newFolder ? newName.trimmed : folder == topLevel ? "" : baseName(folder)
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                Text("Folder").foregroundStyle(.secondary)
                Picker("Folder", selection: $folder) {
                    Text("Meetings (top level)").tag(topLevel)
                    ForEach(model.library.tree?.allFolders ?? []) { Text(folderPath($0.path)).tag($0.path) }
                    Divider()
                    Text("New folder…").tag(newFolder)
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }
            if folder == newFolder {
                GridRow {
                    Text("New folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Folder name", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        Text("Created at the top level of your Meetings folder.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Title").foregroundStyle(.secondary)
                TextField(folderName.isEmpty && folder == newFolder ? "Leave blank to use the new folder’s name" : "Leave blank to use “\(folderName.isEmpty ? "Untitled meeting" : folderName)”", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .focused($focus, equals: .title)
            }
            let templates = model.config.summaryTemplateChoices
            if !templates.isEmpty {
                GridRow {
                    Text("Summary template").foregroundStyle(.secondary)
                    Picker("Summary template", selection: Binding(
                        get: { model.config.summaryTemplate(named: summaryTemplate)?.name },
                        set: { summaryTemplate = $0 }
                    )) {
                        Text("Default").tag(nil as String?)
                        ForEach(templates, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
            GridRow {
                Text("Microphone").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    MicPicker(devices: devices ?? []).frame(maxWidth: 360, alignment: .leading)
                    if let devices {
                        let hint = micHint(model.config.mic, devices)
                        Text(hint.text).font(.caption).foregroundStyle(hint.color)
                    }
                }
            }
            if let event {
                let calendars = model.calendar.labels(for: event)
                if !calendars.isEmpty {
                    GridRow(alignment: .top) {
                        Text(calendars.count == 1 ? "Calendar" : "Calendars").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(calendars) { calendar in
                                HStack(spacing: 5) {
                                    CalendarBadges(calendars: [calendar])
                                    Text(calendar.name).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: 360, alignment: .leading)
                    }
                }
            }
            if let event, !others(event).isEmpty {
                GridRow(alignment: .top) {
                    Text("Attendees").foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(others(event), id: \.email) { a in
                            HStack(spacing: 6) {
                                Avatar(name: attendeeName(a), size: 20)
                                Text(attendeeName(a))
                            }
                            .padding(.leading, 2).padding(.trailing, 9).padding(.vertical, 2)
                            .background(Capsule().fill(Color.fill))
                            .help(a.email)
                        }
                    }
                }
            }
        }
    }

    /// Everyone invited except you.
    private func others(_ event: CalendarEvent) -> [CalendarEvent.Attendee] { otherAttendees(event, myName: model.config.myName) }

    // MARK: Open to-dos from last time

    /// The top level isn't a series, so there's nothing to carry over from "last time".
    private var candidates: [TreeNode] {
        folder == newFolder || folder == topLevel ? [] : Array(listedIn(model.library.tree?.find(folder)).prefix(8))
    }
    /// Re-read only when the folder or its meetings change: ticking a to-do rewrites todo.md, which
    /// refreshes the tree, and that mustn't reset the list (a mis-tick stays visible to undo).
    private var candidateKey: String { folder + "\n" + candidates.map(\.path).joined(separator: "\n") }

    /// Open to-dos from the latest earlier meeting in this folder that had any. Only their todo.md
    /// files are read, off the main thread.
    private func loadPrevious() async {
        previous = nil
        ticked = []
        let meetings = model.library.meetings, paths = candidates.map(\.path)
        let found = await Task.detached {
            paths.lazy.compactMap { path in (try? meetings.readTodo(path)).flatMap { parseTodos($0).isEmpty ? nil : (path, $0) } }.first
        }.value
        // Another folder was chosen meanwhile: its own read is on its way.
        guard !Task.isCancelled, let found, let m = candidates.first(where: { $0.path == found.0 }) else { return }
        previous = (found.0, meetingDate(m), found.1)
    }

    private var openTodos: [Todo] {
        guard let previous else { return [] }
        return parseTodos(previous.todo).filter { !$0.done || ticked.contains($0.line) }
    }

    private var previousTodos: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Open to-dos from \(previous?.date.map { compactDate($0) } ?? "last time")")
                Spacer()
                Text("Ticking one ticks it in that meeting").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(openTodos, id: \.line) { t in
                TodoRow(todo: t, alignment: .center, tick: { tick(t) }) {
                    EmptyView()
                } trailing: {
                    Text(ownerLabel(t.owner, model.config.myName)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tick(_ t: Todo) {
        guard let p = previous else { return }
        // The file is ticked as it is now, not written over with the copy this screen has been holding.
        model.library.tick(p.path, t, undo: undoManager) { [previous = $previous, ticked = $ticked] text in
            guard let text else {
                Task { await loadPrevious() }
                return
            }
            previous.wrappedValue = (p.path, p.date, text)
            ticked.wrappedValue.insert(t.line)
        }
    }

    // MARK: Prep notes

    private var prepNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Prep notes")
                Spacer()
                Text("Kept until the call, then carried into its notes").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(prep.enumerated()), id: \.offset) { index, p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Chip(text: "Prep", style: .prep)
                    Text(p).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { setPrep(prep.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                        // 24 points to click around a small ✕, which stays on the line's baseline.
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove this prep note").accessibilityLabel("Remove “\(p)”")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Chip(text: "Prep", style: .outline)
                // Grows to take a pasted list, which then becomes a note per line.
                TextField("An agenda point or question, then Return. Or paste a list.", text: $prepDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focus, equals: .prep)
                    .onSubmit { addPrep(prepDraft) }
                    .onChange(of: prepDraft) { if prepDraft.contains(where: \.isNewline) { addPrep(prepDraft) } }
            }
        }
    }

    /// Prep notes are saved as they change, so they're still here when you come back to this call.
    private func setPrep(_ notes: [String]) {
        prep = notes
        do { try PrepNotes.save(event?.id, notes) } catch { model.toast(error.localizedDescription, isError: true) }
    }

    private func addPrep(_ text: String) {
        let lines = prepLines(text)
        prepDraft = ""
        if !lines.isEmpty { setPrep(prep + lines) }
    }

    private func start() {
        guard !starting else { return } // a held or repeated Return
        if folder == newFolder && newName.trimmed.isEmpty { return error = "Give the new folder a name first." }
        error = ""
        starting = true
        do {
            var target = folder == topLevel ? "" : folder
            if folder == newFolder {
                // A top-level folder with this name already exists: use it.
                if let existing = model.library.tree?.subfolders.first(where: { loose($0.name) == loose(newName) }) {
                    target = existing.path
                } else {
                    target = try model.library.meetings.createFolder(in: "", named: newName)
                }
            }
            let notes = prep + prepLines(prepDraft)
            let name = title.trimmed.isEmpty ? (folderName.isEmpty ? "Untitled meeting" : folderName) : title.trimmed
            try model.recording.startRecording(title: name, folder: target,
                                     options: .init(eventId: event?.id, prep: notes,
                                                    attendees: event.map { others($0).map(attendeeName) } ?? [],
                                                    summaryTemplate: model.config.summaryTemplate(named: summaryTemplate)?.name,
                                                    calendarIDs: event.map { model.calendar.sourceIDs(for: $0) } ?? []))
        } catch {
            self.error = error.localizedDescription
            starting = false
        }
    }
}

// MARK: - Microphones

private let sameAsMac = ""

/// "Same as Mac" (the hint beside it names the microphone that is), each microphone, and the saved
/// one if it's gone, marked "(not connected)" when asked.
func micChoices(_ mic: MicChoice?, _ devices: [InputDevice], markMissing: Bool = true) -> [(value: String, label: String, missing: Bool)] {
    var out: [(String, String, Bool)] = [(sameAsMac, "Same as Mac", false)]
    out += devices.map { ($0.uid, $0.name, false) }
    if let mic, !devices.contains(where: { $0.uid == mic.uid }) { out.append((mic.uid, markMissing ? "\(mic.name) (not connected)" : mic.name, true)) }
    return out
}

/// What will record, for the hint under the picker.
func micHint(_ mic: MicChoice?, _ devices: [InputDevice]) -> (text: String, color: Color) {
    guard let current = devices.first(where: \.isDefault) ?? devices.first else {
        return ("No microphone found. Connect one to record your side of the call.", .red)
    }
    if let mic, !devices.contains(where: { $0.uid == mic.uid }) {
        return ("\(mic.name) isn’t connected, so Oatcake will use \(current.name).", .amber)
    }
    return ("Records from \(mic?.name ?? current.name).", .secondary)
}

func chooseMic(_ value: String, _ devices: [InputDevice], current: MicChoice?) -> MicChoice? {
    if value == sameAsMac { return nil }
    return devices.first { $0.uid == value }.map { MicChoice(uid: $0.uid, name: $0.name) } ?? current
}

/// The microphone picker used on New recording and in Settings.
struct MicPicker: View {
    @Environment(AppModel.self) private var model
    let devices: [InputDevice]

    var body: some View {
        Picker("Microphone", selection: Binding(get: { model.config.mic?.uid ?? sameAsMac },
                                                set: { model.setMic(chooseMic($0, devices, current: model.config.mic)) })) {
            ForEach(micChoices(model.config.mic, devices, markMissing: false), id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !current.items.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(i)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
