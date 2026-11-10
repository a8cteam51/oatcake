import OatcakeCore
import SwiftUI

private let topLevel = "\u{0}top"
private let newFolder = "\u{0}new"

private func eventWhen(_ e: CalendarEvent) -> String {
    let cal = Calendar.current
    let day = cal.isDateInToday(e.startDate) ? "Today" : cal.isDateInTomorrow(e.startDate) ? "Tomorrow" : weekday(e.startDate)
    return ["\(day) · \(hhmm(e.startDate))–\(hhmm(e.endDate))", e.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
}

struct NewRecordingView: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent?

    @ViewState private var folder = topLevel
    @ViewState private var newName = ""
    @ViewState private var title = ""
    @ViewState private var prep: [String] = []
    @ViewState private var prepDraft = ""
    @ViewState private var error = ""
    @ViewState private var starting = false
    @ViewState private var devices: [InputDevice]?
    @ViewState private var previous: (path: String, date: Date?, todo: String)?
    @ViewState private var ticked = Set<Int>()
    @ViewState private var ready = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    if let event { Label(eventWhen(event), systemImage: "calendar").foregroundStyle(.secondary) }
                    PageTitle(text: "New recording")
                }
                form
                if !openTodos.isEmpty { previousTodos }
                prepNotes
                if !error.isEmpty { Notice(tone: .red) { Text(error) } }
                HStack(spacing: 10) {
                    Button(action: start) {
                        Label(starting ? "Starting…" : "Start recording", systemImage: "circle.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(starting)
                    if let link = event?.callLink, let url = URL(string: link) {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Join the call", systemImage: "video") }
                            .controlSize(.large)
                            .help("Opens \(callApp(link) ?? "the call")")
                    }
                    Button("Cancel") { model.openFolder(model.folder) }.controlSize(.large).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                (Text("New recording").fontWeight(.semibold) + Text(event.map { " · \($0.title)" } ?? "").foregroundStyle(.secondary)).lineLimit(1)
            }
        }
        .task {
            if !ready { setUp() }
            await refreshDevices()
        }
        .task(id: candidateKey) { await loadPrevious() }
    }

    /**
     * Where a calendar event's recording goes: the folder named like the event (punctuation ignored).
     * A recurring event with no such folder gets a new one named after it; a one-off goes at the top
     * level. Without an event, the folder selected in the sidebar.
     */
    private func setUp() {
        ready = true
        title = event?.title ?? ""
        guard let event else {
            folder = model.folder.isEmpty ? topLevel : model.folder
            return
        }
        if let tree = model.tree, let match = matchingFolder(event.title, in: tree) {
            folder = match
        } else if event.seriesId != nil {
            folder = newFolder
            // Folder names can't contain "/" or ":" ("Sam & Alex 1:1" becomes "Sam & Alex 1-1").
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
                    ForEach(model.tree?.allFolders ?? []) { Text(folderPath($0.path)).tag($0.path) }
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
                TextField("Leave blank to use “\(folderName.isEmpty ? (folder == newFolder ? "the new folder’s name" : "Untitled meeting") : folderName)”", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(start)
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
        folder == newFolder || folder == topLevel ? [] : Array(listedIn(model.tree?.find(folder)).prefix(8))
    }
    /// Re-read only when the folder or its meetings change: ticking a to-do rewrites todo.md, which
    /// refreshes the tree, and that mustn't reset the list (a mis-tick stays visible to undo).
    private var candidateKey: String { folder + "\n" + candidates.map(\.path).joined(separator: "\n") }

    /// Open to-dos from the latest earlier meeting in this folder that had any.
    private func loadPrevious() async {
        previous = nil
        ticked = []
        for m in candidates {
            guard let todo = try? model.readMeeting(m.path).todo, !parseTodos(todo).isEmpty else { continue }
            previous = (m.path, meetingDate(m), todo)
            return
        }
    }

    private var openTodos: [Todo] {
        guard let previous else { return [] }
        return parseTodos(previous.todo).filter { !$0.done || ticked.contains($0.line) }
    }

    private var previousTodos: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Open to-dos from \(previous?.date.map(shortDate) ?? "last time")")
                Spacer()
                Text("Ticking one updates that meeting’s todo.md").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(openTodos, id: \.line) { t in
                HStack(spacing: 10) {
                    TodoCheckbox(checked: t.done) { tick(t) }
                    Text(t.text).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                    Spacer()
                    Text(ownerLabel(t.owner, model.config.myName)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tick(_ t: Todo) {
        guard let p = previous else { return }
        let todo = toggleTodo(p.todo, line: t.line)
        previous = (p.path, p.date, todo)
        ticked.insert(t.line)
        do { try model.writeMeetingFile(p.path, .todo, todo) } catch { model.toast(error.localizedDescription) }
    }

    // MARK: Prep notes

    private var prepNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Prep notes")
                Spacer()
                Text("Carried into the call’s notes").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(prep.enumerated()), id: \.offset) { _, p in
                HStack(spacing: 10) {
                    Chip(text: "Prep", style: .prep)
                    Text(p)
                }
            }
            HStack(spacing: 10) {
                Chip(text: "Prep", style: .outline)
                TextField("An agenda point or question, then Return", text: $prepDraft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard !prepDraft.trimmed.isEmpty else { return }
                        prep.append(prepDraft.trimmed)
                        prepDraft = ""
                    }
            }
        }
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
                if let existing = model.tree?.subfolders.first(where: { loose($0.name) == loose(newName) }) {
                    target = existing.path
                } else {
                    target = try Meetings(root: model.config.meetingsRoot).createFolder(in: "", named: newName)
                }
            }
            let notes = prepDraft.trimmed.isEmpty ? prep : prep + [prepDraft.trimmed]
            let name = title.trimmed.isEmpty ? (folderName.isEmpty ? "Untitled meeting" : folderName) : title.trimmed
            try model.startRecording(title: name, folder: target,
                                     options: .init(eventId: event?.id, prep: notes, attendees: event.map { others($0).map(attendeeName) } ?? []))
        } catch {
            self.error = error.localizedDescription
            starting = false
        }
    }
}

// MARK: - Microphones

private let sameAsMac = ""

/// "Same as Mac (now …)", each microphone, and the saved one if it's gone, marked "(not connected)" when asked.
func micChoices(_ mic: MicChoice?, _ devices: [InputDevice], markMissing: Bool = true) -> [(value: String, label: String, missing: Bool)] {
    let current = devices.first(where: \.isDefault) ?? devices.first
    var out: [(String, String, Bool)] = [(sameAsMac, current.map { "Same as Mac (now \($0.name))" } ?? "Same as Mac (no microphone found)", false)]
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
