import OatcakeCore
import SwiftUI

/// Every meeting's to-dos in one place. Ticking one updates that meeting's todo.md.
struct TodosView: View {
    @Environment(AppModel.self) private var model
    enum Status: Hashable { case open, done, all }
    enum Grouping: Hashable { case due, folder, owner }

    @ViewState private var status = Status.open
    @ViewState private var grouping = Grouping.due
    @ViewState private var owner = "all"
    @ViewState private var adding = false
    /// Ticked on this page: they stay (faded) in Open until you leave, so a mis-tick can be undone.
    @ViewState private var touched = Set<String>()
    @ViewState private var draft = ""
    /// Ticks not yet read back from disk, so two quick ticks in one meeting don't undo each other.
    @ViewState private var local: [String: String] = [:]
    @FocusState private var addFocused: Bool

    private let day: TimeInterval = 86_400

    var body: some View {
        let myName = model.config.myName
        let today = Calendar.current.startOfDay(for: Date())
        let items = allTodoItems(model.todoMeetings.map { m in
            var m = m
            if let text = local[m.path] { m.todo = text }
            return m
        })
        let open = items.filter { !$0.todo.done }
        let overdue = items.filter { $0.isOverdue(today: today) }
        var list = items.filter { status == .open ? !$0.todo.done || touched.contains($0.id) : status == .done ? $0.todo.done : true }
        if owner == "mine" { list = list.filter { isMe($0.todo.owner, myName) } } else if owner != "all" { list = list.filter { $0.todo.owner == owner } }
        list.sort { a, b in
            let da = a.dueDate ?? .distantFuture, db = b.dueDate ?? .distantFuture
            return da != db ? da < db : (a.meeting.startedAt ?? .distantPast) > (b.meeting.startedAt ?? .distantPast)
        }
        let groups = grouped(list, today: today, myName: myName)
        let owners = Array(Set(items.map(\.todo.owner).filter { !$0.isEmpty && !isMe($0, myName) })).sorted()
        // Your own list (the Meetings folder's todo.md) isn't a meeting.
        let fromMeetings = Set(open.filter { !$0.meeting.path.isEmpty }.map(\.meeting.path)).count
        let fromYourList = open.contains { $0.meeting.path.isEmpty }
        let sources = [fromMeetings > 0 ? "\(fromMeetings) meeting\(fromMeetings == 1 ? "" : "s")" : nil, fromYourList ? "your list" : nil]
            .compactMap { $0 }.joined(separator: " and ")

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "To-dos")
                Text("\(open.count) open\(overdue.isEmpty ? "" : " · \(overdue.count) overdue")\(sources.isEmpty ? "" : " · from \(sources)"). Ticking one updates that meeting’s todo.md.")
                    .foregroundStyle(.secondary).padding(.top, 6)
                HStack(spacing: 10) {
                    Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.quaternary)
                    TextField("Add a to-do, then Return", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($addFocused)
                        .help("Yours unless you name someone: Send the deck - Alex - due Fri, Nov 6")
                        .onSubmit(add)
                }
                .padding(.top, 22)
                // How adding works, only while adding.
                if addFocused {
                    Text("Saved in your Meetings folder’s own todo.md, as yours unless you name someone: Send the deck - Alex - due Fri, Nov 6. To add one to a meeting, use the to-dos at the top of its summary.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                ForEach(groups, id: \.key) { group in
                    HStack(spacing: 6) {
                        if grouping == .owner, let o = group.items.first?.todo.owner, !o.isEmpty { Avatar(name: o, size: 18) }
                        Text(group.label).foregroundStyle(group.key == "0" && grouping == .due ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        Text("\(group.items.count)").foregroundStyle(.tertiary)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                    ForEach(group.items) { item in row(item, today: today, myName: myName) }
                }
                if groups.isEmpty {
                    Text(status == .done ? "Nothing ticked off yet." : owner == "all" ? "No open to-dos." : "No open to-dos for this person.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: model.todoMeetings) {
            local = local.filter { path, text in model.todoMeetings.first { $0.path == path }?.todo != text }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: Binding(get: { status }, set: { status = $0; touched = [] })) {
                    Text("Open · \(open.count)").tag(Status.open)
                    Text("Done").tag(Status.done)
                    Text("All").tag(Status.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .automatic) {
                Picker("Group by", selection: $grouping) {
                    Text("Due date").tag(Grouping.due)
                    Text("Folder").tag(Grouping.folder)
                    Text("Owner").tag(Grouping.owner)
                }
                .fixedSize()
                Picker("Owner", selection: $owner) {
                    Text("Everyone").tag("all")
                    Text("Mine").tag("mine")
                    ForEach(owners, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
        }
    }

    private struct Group {
        var key: String
        var label: String
        var items: [TodoItem]
    }

    private func grouped(_ list: [TodoItem], today: Date, myName: String) -> [Group] {
        // Calendar weeks: "This week" runs to Sunday, "Next week" the seven days after.
        let weekday = Calendar.current.component(.weekday, from: today)
        let endOfWeek = today.addingTimeInterval(Double((8 - weekday) % 7) * day)
        func bucket(_ t: TodoItem) -> (String, String) {
            guard let d = t.dueDate else { return ("6", "No due date") }
            if d < today { return t.todo.done ? ("1", "Was due earlier") : ("0", "Overdue") }
            if d == today { return ("2", "Today") }
            if d <= endOfWeek { return ("3", "This week") }
            if d <= endOfWeek.addingTimeInterval(7 * day) { return ("4", "Next week") }
            return ("5", "Later")
        }
        func key(_ t: TodoItem) -> (String, String) {
            switch grouping {
            case .folder:
                let f = t.meeting.path.isEmpty ? "" : parentOf(t.meeting.path)
                return (folderPath(f), folderPath(f))
            case .owner:
                if isMe(t.todo.owner, myName) { return ("0", "You") }
                return t.todo.owner.isEmpty ? ("2", "No owner") : ("1" + t.todo.owner, t.todo.owner)
            case .due:
                return bucket(t)
            }
        }
        var groups: [String: Group] = [:]
        for t in list {
            let (k, label) = key(t)
            groups[k, default: Group(key: k, label: label, items: [])].items.append(t)
        }
        return groups.values.sorted { $0.key < $1.key }
    }

    private func row(_ item: TodoItem, today: Date, myName: String) -> some View {
        let late = item.isOverdue(today: today)
        let folder = item.meeting.path.isEmpty ? "" : parentOf(item.meeting.path)
        let date = item.meeting.startedAt.map(shortDate) ?? ""
        return HStack(alignment: .top, spacing: 10) {
            TodoCheckbox(checked: item.todo.done) { tick(item) }.padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.todo.text).strikethrough(item.todo.done).textSelection(.enabled)
                HStack(spacing: 8) {
                    if item.meeting.path.isEmpty {
                        Text("Your list").foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.openMeeting(item.meeting.path, jump: Jump(tab: .summary))
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(folder.isEmpty ? Color.secondary : Color.accentColor).frame(width: 6, height: 6)
                                Text(grouping == .folder ? (date.isEmpty ? "Open meeting" : date) : "\(folder.isEmpty ? "Meetings" : baseName(folder))\(date.isEmpty ? "" : " · \(date)")")
                            }
                        }
                        .buttonStyle(.link)
                        .help("Open this meeting")
                    }
                    if !item.todo.stamp.isEmpty {
                        Chip(text: item.todo.stamp) { model.openMeeting(item.meeting.path, jump: Jump(tab: .transcript, stamp: item.todo.stamp)) }
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            // Grouped by owner, the group heading already names them.
            if grouping != .owner, !item.todo.owner.isEmpty {
                HStack(spacing: 5) {
                    Avatar(name: item.todo.owner, size: 18)
                    Text(isMe(item.todo.owner, myName) ? "You" : item.todo.owner).lineLimit(1)
                }
                .font(.callout)
                .frame(width: 150, alignment: .leading)
            }
            Text(dueLabel(item, today: today))
                .font(.callout).monospacedDigit()
                .foregroundStyle(late ? AnyShapeStyle(.red) : item.dueDate == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .opacity(item.todo.done && status == .open ? 0.55 : 1)
    }

    private func dueLabel(_ item: TodoItem, today: Date) -> String {
        guard let due = item.dueDate else { return "No date" }
        let d = Int((due.timeIntervalSince(today) / day).rounded())
        return d == 0 ? "Today" : d == 1 ? "Tomorrow" : item.todo.due
    }

    /// To-dos added here go in the Meetings folder's own todo.md, owned by you unless you name someone.
    private func add() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        let own = local[""] ?? model.todoMeetings.first { $0.path.isEmpty }?.todo ?? ""
        do {
            let todo = addTodo(own, typedTodo(text, owner: model.config.myName))
            try model.writeMeetingFile("", .todo, todo)
            local[""] = todo
            draft = ""
            model.toast("Added to Meetings › todo.md")
        } catch {
            model.toast(error.localizedDescription)
        }
        model.refresh()
    }

    private func tick(_ item: TodoItem) {
        do {
            let todo = toggleTodo(item.meeting.todo, line: item.todo.line)
            try model.writeMeetingFile(item.meeting.path, .todo, todo)
            local[item.meeting.path] = todo
            touched.insert(item.id)
            model.toast("Saved to \(item.meeting.path.isEmpty ? "Meetings" : folderPath(item.meeting.path)) › todo.md")
        } catch {
            model.toast(error.localizedDescription)
        }
        model.refresh()
    }
}
