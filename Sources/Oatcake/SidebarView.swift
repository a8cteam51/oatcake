import OatcakeCore
import SwiftUI

/// What a drag from the meeting list or the folder tree carries: an item's path in the Meetings folder.
let dragPrefix = "oatcake-item:"

enum SidebarItem: Hashable {
    case live, todos, job(String), folder(String)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var open: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "openFolders") ?? [])
    @ViewState private var renaming: TreeNode?
    @ViewState private var draft = ""
    @ViewState private var newFolderIn: String?
    @ViewState private var dropTarget: String?

    var body: some View {
        List(selection: selectionBinding) {
            if let live = model.live { liveRow(live).tag(SidebarItem.live) }
            todosRow.tag(SidebarItem.todos)
            if model.calendar != nil { upcoming }
            if !model.jobs.isEmpty {
                Section("Needs review") {
                    ForEach(model.jobs) { job in jobRow(job).tag(SidebarItem.job(job.id)) }
                }
            }
            Section {
                if let tree = model.tree {
                    ForEach(tree.subfolders) { FolderTree(node: $0, open: $open, renaming: $renaming, draft: $draft, newFolderIn: $newFolderIn, dropTarget: $dropTarget) }
                    if tree.subfolders.isEmpty { Text("No folders yet.").foregroundStyle(.secondary).font(.callout) }
                }
            } header: {
                HStack {
                    Text("Meetings")
                    Spacer()
                    Button { newFolderIn = ""; draft = "" } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).help("New folder")
                }
                .contentShape(Rectangle())
                .onTapGesture { model.openFolder("") }
                .help("All meetings")
                .dropDestination(for: String.self) { items, _ in drop(items, on: "") } isTargeted: { dropTarget = $0 ? "" : nil }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button { newRecording() } label: {
                Label("New recording", systemImage: "circle.fill")
                    .labelStyle(NewRecordingLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("New recording")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                UpdateNotice()
                Divider()
                SettingsLink {
                    Label("Settings", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .help("Settings (⌘,)")
            }
            .background(.bar)
        }
        .onChange(of: open) { UserDefaults.standard.set(Array(open), forKey: "openFolders") }
        .onChange(of: model.folder) { revealSelectedFolder() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { if let node = renaming { model.rename(node.path, to: draft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderIn != nil }, set: { if !$0 { newFolderIn = nil } })) {
            TextField("Folder name", text: $draft)
            Button("Create") {
                guard let parent = newFolderIn, !draft.trimmed.isEmpty else { return }
                if model.createFolder(in: parent, named: draft) != nil, !parent.isEmpty { open.insert(parent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let parent = newFolderIn, !parent.isEmpty { Text("Inside \(folderPath(parent))") }
        }
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            switch model.selection {
            case .live: .live
            case .todos: .todos
            case .job(let id): .job(id)
            case .meeting, .folder, nil: .folder(model.folder)
            case .new: nil
            }
        } set: { item in
            switch item {
            case .live: model.selection = .live
            case .todos: model.selection = .todos
            case .job(let id): model.selection = .job(id)
            case .folder(let path): model.openFolder(path)
            case nil: break
            }
        }
    }

    private func newRecording(_ event: CalendarEvent? = nil) {
        model.selection = model.live != nil ? .live : .new(event)
    }

    /// A selected folder's parents open, so it's visible.
    private func revealSelectedFolder() {
        let parts = model.folder.split(separator: "/").map(String.init)
        for i in parts.indices.dropLast() { open.insert(parts[...i].joined(separator: "/")) }
    }

    private func drop(_ items: [String], on target: String) -> Bool {
        guard let item = items.first, item.hasPrefix(dragPrefix) else { return false }
        model.move(String(item.dropFirst(dragPrefix.count)), into: target)
        return true
    }

    // MARK: Rows

    private func liveRow(_ rec: Recording) -> some View {
        let starting = model.status.state != .recording
        return HStack(spacing: 9) {
            if starting { Circle().fill(.secondary).frame(width: 7, height: 7) } else { RecDot() }
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.title).lineLimit(1)
                Text(starting ? "Starting…" : "Recording · \(clock(model.status.elapsed ?? 0))")
                    .font(.caption).foregroundStyle(starting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).monospacedDigit()
            }
        }
    }

    private var todosRow: some View {
        let counts = model.todoCounts
        return HStack {
            Label("To-dos", systemImage: "checkmark.square")
            Spacer()
            if counts.overdue > 0 { Text("\(counts.overdue) overdue").font(.caption.weight(.medium)).foregroundStyle(.red) }
            if counts.open > 0 { Text("\(counts.open)").foregroundStyle(.secondary).monospacedDigit().help("Open to-dos") }
        }
        .help("To-dos from every meeting")
    }

    @ViewBuilder private var upcoming: some View {
        let calendar = model.calendar!
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
            // Upcoming: the rest of today and tomorrow, timed events only.
            let events = Array(calendar.events.filter { !$0.allDay && $0.endDate > now && $0.startDate < endOfTomorrow }.prefix(6))
            let next = events.first { $0.startDate > now }
            Section {
                ForEach(events) { event in
                    Button { newRecording(event) } label: { eventRow(event, next: next, now: now) }
                        .buttonStyle(.plain)
                        .help("\(event.title) · \(hhmm(event.startDate))–\(hhmm(event.endDate))\(event.callLink.map { " · " + (callApp($0) ?? "") } ?? "")")
                }
                if let message = calendarMessage(calendar, events: events) {
                    Text(message).font(.callout).foregroundStyle(calendar.error != nil && calendar.updatedAt == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            } header: {
                HStack {
                    Text("Upcoming")
                    Spacer()
                    Button { model.refreshCalendar(force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(calendar.error != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .symbolEffect(.rotate, isActive: model.calendarFetching)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.calendarFetching)
                    .help("\(calendarTip(calendar)). Refresh now.")
                }
            }
        }
    }

    private func eventRow(_ e: CalendarEvent, next: CalendarEvent?, now: Date) -> some View {
        // Status and countdown sit in the time column, so they never cut the title short.
        let recording = model.live?.eventId == e.id
        let starting = model.status.state != .recording
        let minsToNext = next.map { Int(ceil($0.startDate.timeIntervalSince(now) / 60)) } ?? .max
        let label: String
        let color: AnyShapeStyle
        var bold = true
        if recording {
            label = starting ? "Starting…" : "Recording"
            color = starting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
            bold = !starting
        } else if e == next && minsToNext <= 60 {
            label = "in \(minsToNext)m"
            color = AnyShapeStyle(.tint)
        } else if e.startDate <= now {
            label = "Now"
            color = AnyShapeStyle(.tint)
        } else {
            label = Calendar.current.isDate(e.startDate, inSameDayAs: now) ? hhmm(e.startDate) : "\(shortWeekday(e.startDate)) \(hhmm(e.startDate))"
            color = AnyShapeStyle(.secondary)
            bold = false
        }
        return HStack(spacing: 6) {
            Text(label).font(.caption.weight(bold ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(color).frame(width: 62, alignment: .leading)
            Text(e.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func calendarTip(_ c: CalendarCache) -> String {
        if model.calendarFetching { return "Fetching…" }
        if let error = c.error { return error }
        if let updated = parseISO(c.updatedAt) { return "Updated \(hhmm(updated))" }
        return "Not fetched yet"
    }

    private func calendarMessage(_ c: CalendarCache, events: [CalendarEvent]) -> String? {
        if c.updatedAt == nil { return c.error ?? "Fetching your calendar…" }
        return events.isEmpty ? "Nothing else today or tomorrow." : nil
    }

    private func jobRow(_ job: AppModel.Job) -> some View {
        HStack(spacing: 9) {
            Group {
                switch job.status {
                case .processing: ProgressView().controlSize(.mini)
                case .review: Circle().fill(.tint).frame(width: 8, height: 8)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.rec.title).lineLimit(1)
                Text("\(jobStatus(job)) · \(jobWhen(job.rec.startedAt))")
                    .font(.caption).foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
    }

    private func jobStatus(_ job: AppModel.Job) -> String {
        switch job.status {
        case .processing: "Processing · step \(job.step) of 5"
        case .review: "Ready to review"
        case .failed: "Couldn’t finish"
        }
    }

    /// "21:10" today, otherwise "Nov 4, 21:10": tells two recordings of the same call apart.
    private func jobWhen(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? hhmm(d) : "\(shortMonth(d)) \(Calendar.current.component(.day, from: d)), \(hhmm(d))"
    }
}

private struct NewRecordingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(.red).font(.system(size: 9))
            configuration.title.fontWeight(.medium)
        }
    }
}

/// One folder in the sidebar, with its subfolders (meetings are listed in the middle column).
private struct FolderTree: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode
    @Binding var open: Set<String>
    @Binding var renaming: TreeNode?
    @Binding var draft: String
    @Binding var newFolderIn: String?
    @Binding var dropTarget: String?

    var body: some View {
        if node.subfolders.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: Binding(get: { open.contains(node.path) }, set: { if $0 { open.insert(node.path) } else { open.remove(node.path) } })) {
                ForEach(node.subfolders) { FolderTree(node: $0, open: $open, renaming: $renaming, draft: $draft, newFolderIn: $newFolderIn, dropTarget: $dropTarget) }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        HStack {
            Label(node.name, systemImage: "folder")
            Spacer()
            let count = node.meetings.count
            if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
        }
        .tag(SidebarItem.folder(node.path))
        .listRowBackground(dropTarget == node.path ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2)) : nil)
        .draggable(dragPrefix + node.path)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix(dragPrefix) else { return false }
            model.move(String(item.dropFirst(dragPrefix.count)), into: node.path)
            return true
        } isTargeted: { dropTarget = $0 ? node.path : (dropTarget == node.path ? nil : dropTarget) }
        .contextMenu {
            Button("Rename…") { draft = node.name; renaming = node }
            Button("New Folder Inside…") { draft = ""; newFolderIn = node.path }
            Button("Show in Finder") { model.reveal(node.path) }
            Divider()
            Button("Move to Trash") { model.trash(node) }
        }
    }
}

/// A newer release: Update installs it and relaunches; Details (when this copy can't update itself) opens Settings.
private struct UpdateNotice: View {
    @Environment(AppModel.self) private var model

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
                    SettingsLink { Text("Details") }
                } else {
                    Button("Update") { Task { await u.install() } }.buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
