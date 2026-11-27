import OatcakeCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A meeting or folder dragged within Oatcake, to move it. Declared in Oatcake's Info.plist.
    static let oatcakeItem = UTType(exportedAs: "local.oatcake.item")
}

/// What a drag from the meeting list or the folder tree carries. Dropped inside Oatcake, the item's
/// path, to move it; on another app, the folder itself (Finder, Mail), or, where only text goes, the
/// meeting's summary. Dragging several meetings picked in the list brings one item for each.
struct MeetingItem: Codable, Transferable {
    /// Relative to the Meetings folder.
    var path: String
    var folder: URL
    /// The Meetings folder, so the summary given as text is read only if it's really inside it.
    var root: URL

    init(_ path: String, in root: URL) {
        self.path = path
        self.root = root
        folder = root.appendingPathComponent(path, isDirectory: true)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .oatcakeItem)
        ProxyRepresentation { $0.folder }
        DataRepresentation(exportedContentType: .utf8PlainText) { item in
            Data(forReading(fileInside(item.root, item.folder, MeetingFile.summary.rawValue).map(readText) ?? "").trimmed.utf8)
        }
    }
}

enum SidebarItem: Hashable {
    case home, live, todos, job(String), folder(String), meeting(String)
}

/// A section's header runs closer to the sidebar's edge than its rows do. This brings a button at the
/// end of a header back in line with the counts at the end of the rows.
private let headerButtonInset: CGFloat = 14

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var open: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "openFolders") ?? [])
    @ViewState private var renaming: TreeNode?
    @ViewState private var draft = ""
    @ViewState private var newFolderIn: String?
    @ViewState private var dropTarget: String?
    @FocusState private var hasKeyboard: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: selectionBinding) {
            if let live = model.recording.live { LiveRow(rec: live).tag(SidebarItem.live) }
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            if model.config.todosEnabled { todosRow.tag(SidebarItem.todos) }
            if model.calendar.hasCalendars { upcoming }
            if !model.jobs.list.isEmpty {
                Section("Who’s who") {
                    ForEach(model.jobs.list) { job in jobRow(job).tag(SidebarItem.job(job.id)) }
                }
            }
            Section {
                if let tree = model.library.tree {
                    // Every meeting, whatever folder it's in; highlighted while the list shows them.
                    HStack {
                        Label("All meetings", systemImage: "tray.full")
                        Spacer()
                        let count = tree.allMeetings.count
                        if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .tag(SidebarItem.folder(""))
                    ForEach(visibleFolders(tree), id: \.node.path) { item in
                        FolderRow(node: item.node, depth: item.depth, open: $open, renaming: $renaming, draft: $draft,
                                  newFolderIn: $newFolderIn, dropTarget: $dropTarget)
                    }
                    // A one-off call with no folder of its own is saved at the top level. It's listed here
                    // under its call's title, after the folders, to open or to drag into one.
                    ForEach(tree.meetings, id: \.path) { m in
                        topLevelRow(m).tag(SidebarItem.meeting(m.path))
                            .contextMenu { MeetingMenuItems(model: model, node: m) }
                    }
                    if tree.children.isEmpty { Text("No folders yet.").foregroundStyle(.secondary).font(.callout) }
                }
            } header: {
                HStack {
                    Text("Meetings")
                    Spacer()
                    // 24 points to click; the symbol stays at the frame's end, in line with the counts.
                    Button { newFolderIn = ""; draft = "" } label: { Image(systemName: "folder.badge.plus").frame(width: 24, height: 24, alignment: .trailing).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).help("New folder (⇧⌘N)").accessibilityLabel("New folder")
                        .padding(.trailing, 1.5) // This symbol's badge reaches further right than the refresh arrow.
                }
                .padding(.trailing, headerButtonInset)
                .contentShape(Rectangle())
                // Dropped on the heading: to the top level of the Meetings folder.
                .dropDestination(for: MeetingItem.self) { items, _ in drop(items, on: "") } isTargeted: { dropTarget = $0 ? "" : nil }
            }
        }
        .listStyle(.sidebar)
        .focused($hasKeyboard)
        // Made again after choosing a screen with the other number of columns: the keyboard comes
        // back, so ↑ and ↓ carry on from the row just chosen. A moment later, once it's in the window.
        .onAppear {
            guard model.sidebarKeepsKeyboard else { return }
            model.sidebarKeepsKeyboard = false
            DispatchQueue.main.async { hasKeyboard = true }
        }
        // The folder tree from the keyboard, as in Finder: → opens a folder, ← closes it (or goes up
        // to the folder it's in), Return renames, and ⌘⌫ (File › Move to Trash) moves it to the Trash.
        .onKeyPress(.rightArrow) { showFolders(true) }
        .onKeyPress(.leftArrow) { showFolders(false) }
        .onKeyPress(.return) { renameSelected() }
        .focusedValue(\.trashMeetings, trashSelected)
        .safeAreaInset(edge: .top) {
            Button { model.newRecording() } label: {
                HStack(spacing: 8) {
                    // During a call it goes back to that call, so it says so.
                    if model.recording.live != nil {
                        Label("Return to the call", systemImage: "waveform")
                    } else {
                        Label("Record a call", systemImage: "circle.fill")
                            .labelStyle(NewRecordingLabelStyle())
                    }
                    ShortcutHint("⌘N")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help(model.recording.live != nil ? "Return to the call (⌘N)" : "Record a call (⌘N)")
        }
        // Settings is in the Oatcake menu (⌘,) and the menu bar item, as other Mac apps keep it.
        .safeAreaInset(edge: .bottom, spacing: 0) { UpdateNotice() }
        .onChange(of: open) { UserDefaults.standard.set(Array(open), forKey: "openFolders") }
        .onChange(of: model.folder) { revealSelectedFolder() }
        // Also when the sidebar first appears: the window may have been closed when New Folder was chosen.
        .onChange(of: model.wantsNewFolder, initial: true) {
            guard model.wantsNewFolder else { return }
            model.wantsNewFolder = false
            newFolderIn = ""
            draft = ""
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") {
                guard let node = renaming, !model.library.rename(node.path, to: draft) else { return }
                askAgain { renaming = node }
            }
            .disabled(draft.trimmed.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: Binding(get: { newFolderIn != nil }, set: { if !$0 { newFolderIn = nil } })) {
            TextField("Folder name", text: $draft)
            Button("Create") {
                guard let parent = newFolderIn, !draft.trimmed.isEmpty else { return }
                if model.library.createFolder(in: parent, named: draft) == nil {
                    askAgain { newFolderIn = parent }
                } else if !parent.isEmpty {
                    open.insert(parent)
                }
            }
            .disabled(draft.trimmed.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let parent = newFolderIn, !parent.isEmpty { Text("Inside \(folderPath(parent))") }
        }
    }

    /// The row for what the window shows. Until Oatcake has put back where it was, that's Home.
    private var highlighted: SidebarItem? {
        switch model.selection {
        case .home, nil: .home
        case .live: .live
        case .todos: .todos
        case .job(let id): .job(id)
        case .meeting(let path, _) where parentOf(path).isEmpty: .meeting(path)
        case .meeting, .folder: .folder(model.folder)
        case .new: nil
        }
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            highlighted
        } set: { item in
            // The list can hand back the row it was given as it's laid out. That's no choice: taken for
            // one, it could open All meetings before the Meetings folder had been read, and Oatcake then
            // left the window there rather than putting back the screen it was on.
            guard item != highlighted else { return }
            let listShown = model.listShown
            switch item {
            case .home: model.selection = .home
            case .live: model.selection = .live
            case .todos: model.selection = .todos
            case .job(let id): model.selection = .job(id)
            case .folder(let path): model.openFolder(path)
            case .meeting(let path): model.openMeeting(path)
            case nil: break
            }
            // Only the list itself chooses here, by the arrow keys or a click, either of which leaves
            // it with the keyboard. ⌘N, the menus and the meeting list don't come this way.
            if model.listShown != listShown {
                model.sidebarKeepsKeyboard = true
                // Only for this switch: a sidebar squeezed out of a narrow window doesn't appear to take it,
                // and one made later (from the menus, ⌘N) mustn't take the keyboard from the screen.
                Task { @MainActor [model] in
                    try? await Task.sleep(for: .seconds(1))
                    model.sidebarKeepsKeyboard = false
                }
            }
        }
    }

    /// The folders to show, depth first, skipping the inside of closed ones. They're drawn as flat,
    /// indented rows (as the Electron version did) rather than nested disclosure groups, which left
    /// stale highlights and stray rows behind in the sidebar's outline.
    private func visibleFolders(_ tree: TreeNode) -> [(node: TreeNode, depth: Int)] {
        var out: [(TreeNode, Int)] = []
        func walk(_ node: TreeNode, _ depth: Int) {
            for child in node.subfolders {
                out.append((child, depth))
                if open.contains(child.path) { walk(child, depth + 1) }
            }
        }
        walk(tree, 0)
        return out
    }

    /// A selected folder's parents open, so it's visible.
    private func revealSelectedFolder() {
        let parts = model.folder.split(separator: "/").map(String.init)
        for i in parts.indices.dropLast() { open.insert(parts[...i].joined(separator: "/")) }
    }

    private func drop(_ items: [MeetingItem], on target: String) -> Bool {
        guard !items.isEmpty else { return false }
        model.library.move(items.map(\.path), into: target)
        return true
    }

    // MARK: Keys

    /// The folder or top-level meeting highlighted in the sidebar.
    private var selectedNode: TreeNode? {
        switch highlighted {
        case .folder(let path) where !path.isEmpty, .meeting(let path): model.library.tree?.find(path)
        default: nil
        }
    }

    private func showFolders(_ show: Bool) -> KeyPress.Result {
        guard let node = selectedNode, node.kind == .folder else { return .ignored }
        if show {
            guard !node.subfolders.isEmpty else { return .ignored }
            open.insert(node.path)
        } else if open.contains(node.path) {
            open.remove(node.path)
        } else {
            model.openFolder(parentOf(node.path))
        }
        return .handled
    }

    private func renameSelected() -> KeyPress.Result {
        guard let node = selectedNode else { return .ignored }
        if node.kind == .meeting {
            model.renaming = node
        } else {
            draft = node.name
            renaming = node
        }
        return .handled
    }

    /// File › Move to Trash for what's highlighted: a folder asks first if it holds meetings.
    private var trashSelected: (() -> Void)? {
        guard let node = selectedNode else { return nil }
        return node.kind == .folder ? { model.library.trashFolder(node) } : { model.trash([node]) }
    }

    // MARK: Rows

    private func topLevelRow(_ m: TreeNode) -> some View {
        HStack(spacing: 4) {
            Label(meetingTitle(m), systemImage: "doc.text").lineLimit(1)
            Spacer()
            if let date = meetingDate(m) { Text(compactDate(date)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .draggable(MeetingItem(m.path, in: model.library.meetings.root))
    }

    private var todosRow: some View {
        let counts = model.library.todoCounts
        return HStack {
            Label("To-dos", systemImage: "checkmark.square")
            Spacer()
            if counts.overdue > 0 { Text("\(counts.overdue) overdue").font(.caption.weight(.medium)).foregroundStyle(.red) }
            if counts.open > 0 { Text("\(counts.open)").foregroundStyle(.secondary).monospacedDigit().help("Open to-dos") }
        }
        .help("To-dos from every meeting")
    }

    /// Upcoming: the rest of today and tomorrow, timed events only. Its countdowns follow the app's
    /// half-minute tick. (They used to sit in a TimelineView, but a Section built inside one stops
    /// SwiftUI with a fatal error in a sidebar list, so the app couldn't open with a calendar set.)
    @ViewBuilder private var upcoming: some View {
        let calendar = model.calendar
        let now = model.calendar.now
        let events = Array(upcomingCalls(model.calendar.events, at: now).prefix(6))
        let next = events.first { $0.startDate > now }
        Section {
            ForEach(events) { event in UpcomingRow(event: event, next: next, now: now) }
            UpcomingNote(empty: events.isEmpty)
        } header: {
            HStack {
                Text("Upcoming")
                Spacer()
                Button { model.calendar.refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(calendar.hasFailures ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .symbolEffect(.rotate, isActive: model.calendar.fetching && !reduceMotion)
                        .frame(width: 24, height: 24, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh calendars")
                .disabled(calendar.fetching)
                .help("Refresh calendars (⌘R)")
            }
            .padding(.trailing, headerButtonInset)
        }
    }

    private func jobRow(_ job: Jobs.Job) -> some View {
        HStack(spacing: 9) {
            Group {
                switch job.status {
                case .processing: ProgressView().controlSize(.mini)
                case .review: Circle().fill(.tint).frame(width: 8, height: 8)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.rec.title).lineLimit(1)
                Text("\(jobStatus(job)) · \(jobWhen(job.rec.startedAt))")
                    .font(.caption).foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        .contextMenu { Button("Discard…") { model.jobs.discard(job.rec) } }
    }

    private func jobStatus(_ job: Jobs.Job) -> String {
        switch job.status {
        case .processing: "Transcribing · step \(job.step) of 5"
        case .review: "Ready to check"
        case .failed: "Couldn’t finish"
        }
    }

    /// "21:10" today, otherwise "4 Nov at 21:10": tells two recordings of the same call apart.
    private func jobWhen(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? timeOfDay(d) : dateAndTime(d)
    }
}

/// A name or title that couldn't be used (the note at the bottom of the window says why) is asked for
/// again with what was typed, once the alert that took it has gone.
@MainActor func askAgain(_ ask: @escaping @MainActor () -> Void) {
    Task {
        try? await Task.sleep(for: .milliseconds(300))
        ask()
    }
}

/// Said when nothing is left on the calendar today or tomorrow: under Upcoming, and in the menu bar's menu.
let noMoreCalls = "No more calls today or tomorrow"

/// One call under Upcoming, the same in the sidebar and on Home: click it for New recording with it
/// filled in, or right-click it to ignore it.
struct UpcomingRow: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    /// The next call to start, which counts down.
    let next: CalendarEvent?
    let now: Date

    var body: some View {
        let calendars = model.calendar.labels(for: event)
        let names = calendars.map(\.name).joined(separator: ", ")
        let service = event.callLink.flatMap(callApp).map { " · \($0)" } ?? ""
        Button { model.newRecording(event) } label: { label(calendars) }
            .buttonStyle(.plain)
            .accessibilityValue(names)
            .help("\(event.title) · \(timeOfDay(event.startDate))–\(timeOfDay(event.endDate))\(service) · \(names)")
            // A call you won't record that you can't rename or decline (someone else's
            // recurring meeting): only Oatcake stops showing it.
            .contextMenu {
                if event.seriesId != nil {
                    Button("Ignore This One") { model.ignore(event, series: false) }
                    Button("Ignore This and Following Events") { model.ignore(event, series: true) }
                } else {
                    Button("Ignore This Event") { model.ignore(event, series: false) }
                }
            }
    }

    private func label(_ calendars: [CalendarController.Label]) -> some View {
        // Status and countdown sit in the time column, so they never cut the title short.
        let e = event
        let recording = model.recording.live?.eventId == e.id
        let starting = model.recording.status.state != .recording
        let minsToNext = next.map { Int(ceil($0.startDate.timeIntervalSince(now) / 60)) } ?? .max
        let label: String
        let color: AnyShapeStyle
        var bold = true
        if recording {
            label = starting ? "Starting…" : "Recording"
            color = starting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
            bold = !starting
        } else if e == next && minsToNext <= 60 {
            label = "in \(shortDuration(Double(minsToNext) * 60))"
            color = AnyShapeStyle(.tint)
        } else if e.startDate <= now {
            label = "Now"
            color = AnyShapeStyle(.tint)
        } else {
            label = Calendar.current.isDate(e.startDate, inSameDayAs: now) ? timeOfDay(e.startDate) : dayAndTime(e.startDate)
            color = AnyShapeStyle(.secondary)
            bold = false
        }
        return HStack(spacing: 6) {
            // At least the column's width, and more for a 12-hour clock's "Thu 10:30 pm".
            Text(label).font(.caption.weight(bold ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(color).fixedSize().frame(minWidth: 62, alignment: .leading)
            CalendarBadges(calendars: calendars)
            Text(e.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// What Upcoming says when it has no calls to list, or can't be sure it has them all.
struct UpcomingNote: View {
    @Environment(AppModel.self) private var model
    let empty: Bool

    var body: some View {
        Group {
            if model.calendar.hasFailures {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some calendars couldn’t update.")
                    SettingsPaneLink(pane: .calendar, title: "Settings › Calendars").buttonStyle(.link)
                }
            } else if !model.calendar.hasUpdated {
                Text("Fetching calendars…")
            } else if empty {
                Text("\(noMoreCalls).")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct NewRecordingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(.red).font(.system(size: 9))
            configuration.title.fontWeight(.medium)
        }
    }
}

/// The call being recorded. A view of its own, as it reads the recorder's status (twice a second):
/// the rest of the sidebar isn't drawn again each time.
private struct LiveRow: View {
    @Environment(AppModel.self) private var model
    let rec: Recording

    var body: some View {
        // What's true of it: on its way up, recording, or not recording at all.
        let state = model.recording.status.state
        let failed = model.recording.recorderFailure != nil
        let recording = state == .recording && !failed
        let label = failed ? "Couldn’t record" : state == .starting ? "Starting…" : recording ? "Recording · \(clock(model.recording.status.elapsed ?? 0))" : "Recording stopped"
        return HStack(spacing: 9) {
            if recording {
                RecDot()
            } else if failed {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
            } else {
                Circle().fill(.secondary).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.title).lineLimit(1)
                Text(label)
                    .font(.caption).foregroundStyle(recording || failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).monospacedDigit()
            }
        }
    }
}

/// One folder in the sidebar (meetings are listed in the middle column).
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode
    let depth: Int
    @Binding var open: Set<String>
    @Binding var renaming: TreeNode?
    @Binding var draft: String
    @Binding var newFolderIn: String?
    @Binding var dropTarget: String?

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Label(node.name, systemImage: "folder").lineLimit(1)
                if !node.subfolders.isEmpty {
                    Button {
                        if open.contains(node.path) { open.remove(node.path) } else { open.insert(node.path) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open.contains(node.path) ? 90 : 0))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(open.contains(node.path) ? "Hide" : "Show") the folders in \(node.name)")
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            let count = node.meetings.count
            if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit().fixedSize() }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 5).fill(dropTarget == node.path ? Color.accentColor.opacity(0.25) : .clear).padding(-3))
        .tag(SidebarItem.folder(node.path))
        .draggable(MeetingItem(node.path, in: model.library.meetings.root))
        .dropDestination(for: MeetingItem.self) { items, _ in
            guard !items.isEmpty else { return false }
            model.library.move(items.map(\.path), into: node.path)
            return true
        } isTargeted: { dropTarget = $0 ? node.path : (dropTarget == node.path ? nil : dropTarget) }
        .contextMenu {
            Button("Rename…") { draft = node.name; renaming = node }
            Button("New Folder Inside…") { draft = ""; newFolderIn = node.path }
            Button("Show in Finder") { model.library.reveal(node.path) }
            Divider()
            Button("Move to Trash") { model.library.trashFolder(node) }
        }
    }
}

/// A newer release: Update installs it and relaunches; Details (when this copy can't update itself) opens Settings.
private struct UpdateNotice: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirming = false

    var body: some View {
        let u = model.updater
        if let available = u.available {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(u.installing ?? "Oatcake \(available.version) is available").font(.callout.weight(.medium))
                    if let error = u.error, u.installing == nil {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                    }
                }
                Spacer(minLength: 0)
                if u.installing != nil {
                    ProgressView().controlSize(.small)
                } else if u.blocked != nil {
                    // Opens Settings on its Updates pane.
                    SettingsPaneLink(pane: .updates, title: "Details")
                } else {
                    Button("Update…") { confirming = true }.buttonStyle(.borderedProminent)
                        .installQuestion(available.version, isPresented: $confirming) { Task { await u.install() } }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }
            .background(.bar)
        }
    }
}

extension View {
    /// Asked before an update is installed, from the sidebar or Settings: it quits Oatcake, and
    /// whatever is half done in a window goes with it.
    func installQuestion(_ version: String, isPresented: Binding<Bool>, install: @escaping () -> Void) -> some View {
        alert("Install Oatcake \(version)?", isPresented: isPresented) {
            Button("Install and relaunch", action: install)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Oatcake downloads it, quits and reopens on the new version. A Who’s who you haven’t saved yet keeps its audio, but not the names you’ve typed.")
        }
    }
}
