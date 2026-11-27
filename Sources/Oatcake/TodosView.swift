import OatcakeCore
import SwiftUI

/// What the To-dos page was showing, for when you come back to it.
@MainActor private enum Remembered {
    static var status = TodosView.Status.open
    static var grouping = TodosView.Grouping.due
    static var owner = TodosView.Owner.everyone
}

/// Every meeting's to-dos in one place. Ticking one updates that meeting's todo.md.
struct TodosView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    private let homePreview: Bool

    init(homePreview: Bool = false) {
        self.homePreview = homePreview
    }

    enum Status: CaseIterable, Hashable {
        case open, done, all

        var title: String {
            switch self {
            case .open: "Open"
            case .done: "Done"
            case .all: "All"
            }
        }
    }
    enum Grouping: Hashable { case due, folder, owner }
    /// Whose to-dos are listed.
    enum Owner: Hashable { case everyone, mine, named(String) }

    @ViewState private var status = Remembered.status
    @ViewState private var grouping = Remembered.grouping
    @ViewState private var owner = Remembered.owner
    @ViewState private var adding = false
    @ViewState private var draft = ""
    /// The to-do of your own list being edited in place (its item ID), and what it says so far.
    @ViewState private var editing: String?
    @ViewState private var edited = ""
    @FocusState private var editFocused: Bool
    /// A list's text straight after a tick or an add here, until the app has read it back from disk,
    /// so two quick ticks in one meeting don't undo each other.
    @ViewState private var local: [String: String] = [:]
    @FocusState private var addFocused: Bool
    @AppStorage(TextScale.key) private var textScale = 1.0

    var body: some View {
        let myName = model.config.myName
        let today = Calendar.current.startOfDay(for: model.calendar.now)
        // The items were worked out when the to-dos were read. Only a list just ticked or added to
        // here is read afresh, from its text as it is now.
        let items = local.isEmpty ? model.library.todoItems
            : model.library.todoItems.filter { local[$0.meeting.path] == nil } + allTodoItems(model.library.todoMeetings.compactMap { m in
                local[m.path].map { text in with(m) { $0.todo = text } }
            })
        SwiftUI.Group {
            if homePreview {
                preview(items, today: today, myName: myName)
            } else {
                fullPage(items, today: today, myName: myName)
                    .focusedSceneValue(\.todoStatus, $status)
            }
        }
        .onChange(of: model.library.todoMeetings) {
            local = local.filter { path, text in model.library.todoMeetings.first { $0.path == path }?.todo != text }
        }
        .onChange(of: status) { Remembered.status = status }
        .onChange(of: grouping) { Remembered.grouping = grouping }
        .onChange(of: owner) { Remembered.owner = owner }
    }

    @ViewBuilder private func preview(_ items: [TodoItem], today: Date, myName: String) -> some View {
        let open = items.filter { !$0.todo.done }
        let list = open.sorted(by: dueFirst).prefix(5)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("To-dos").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if open.count > list.count {
                    Text("Showing \(list.count) of \(open.count) open")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("View all to-dos") { model.selection = .todos }.buttonStyle(.link)
            }
            if list.isEmpty {
                Text("No open to-dos.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { item in
                    row(item, today: today, myName: myName, showOwner: true)
                    Divider()
                }
                addField.padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line).allowsHitTesting(false) }
        }
    }

    private func dueFirst(_ a: TodoItem, _ b: TodoItem) -> Bool {
        let da = a.dueDate ?? .distantFuture, db = b.dueDate ?? .distantFuture
        return da != db ? da < db : (a.meeting.startedAt ?? .distantPast) > (b.meeting.startedAt ?? .distantPast)
    }

    private func fullPage(_ items: [TodoItem], today: Date, myName: String) -> some View {
        let open = items.filter { !$0.todo.done }
        let overdue = items.filter { $0.isOverdue(today: today) }
        // One ticked in Open leaves the list at once. It's under Done, where a mis-tick can be undone.
        var list = items.filter { status == .open ? !$0.todo.done : status == .done ? $0.todo.done : true }
        switch owner {
        case .everyone: break
        case .mine: list = list.filter { isMe($0.todo.owner, myName) }
        case .named(let name): list = list.filter { $0.todo.owner == name }
        }
        list.sort(by: dueFirst)
        let groups = grouped(list, today: today, myName: myName)
        var owners = Set(items.map(\.todo.owner).filter { !$0.isEmpty && !isMe($0, myName) })
        // The person chosen when you were last here stays a choice, even with none of their to-dos left.
        if case .named(let name) = owner { owners.insert(name) }
        // Your own list (the Meetings folder's todo.md) isn't a meeting.
        let fromMeetings = Set(open.filter { !$0.meeting.path.isEmpty }.map(\.meeting.path)).count
        let fromYourList = open.contains { $0.meeting.path.isEmpty }
        let sources = [fromMeetings > 0 ? "\(fromMeetings) meeting\(fromMeetings == 1 ? "" : "s")" : nil, fromYourList ? "your list" : nil]
            .compactMap { $0 }.joined(separator: " and ")

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "To-dos")
                Text("\(open.count) open\(overdue.isEmpty ? "" : " · \(overdue.count) overdue")\(sources.isEmpty ? "" : " · from \(sources)"). Ticking one ticks it in its meeting too.")
                    .foregroundStyle(.secondary).padding(.top, 6)
                addField.padding(.top, 22)
                // How adding works, shown whether or not the field has the keyboard.
                Text("Goes on your own list, as yours unless you name someone: Send the deck - Jane - due Fri, Nov 6. To add one to a meeting, use the to-dos at the top of its summary.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(groups, id: \.key) { group in
                    HStack(spacing: 6) {
                        if grouping == .owner, let o = group.items.first?.todo.owner, !o.isEmpty { Avatar(name: o, size: 18) }
                        Text(group.label).foregroundStyle(group.key == "0" && grouping == .due ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        Text("\(group.items.count)").foregroundStyle(.secondary)
                    }
                    .font(.scaled(.callout, textScale, weight: .semibold))
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                    ForEach(group.items) { item in row(item, today: today, myName: myName, showOwner: grouping != .owner) }
                }
                if groups.isEmpty {
                    Text(status == .done ? "Nothing ticked off yet." : "No \(status == .all ? "" : "open ")to-dos\(owner == .everyone ? "" : " for this person").")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            // What's shown, then how it's arranged.
            ToolbarItem(placement: .automatic) {
                Picker("Show", selection: $status) {
                    ForEach(Status.allCases, id: \.self) { filter in
                        Text(filter == .open ? "\(filter.title) · \(open.count)" : filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            ToolbarItemGroup(placement: .automatic) {
                // Each value says what it chooses: how the list is grouped, and whose to-dos are in it.
                Picker("Group by", selection: $grouping) {
                    Text("By due date").tag(Grouping.due)
                    Text("By folder").tag(Grouping.folder)
                    Text("By owner").tag(Grouping.owner)
                }
                .fixedSize()
                Picker("Owner", selection: $owner) {
                    Text("Everyone’s").tag(Owner.everyone)
                    Text("Mine").tag(Owner.mine)
                    ForEach(owners.sorted(), id: \.self) { Text("\($0)’s").tag(Owner.named($0)) }
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
        func key(_ t: TodoItem) -> (String, String) {
            switch grouping {
            case .folder:
                let f = t.meeting.path.isEmpty ? "" : parentOf(t.meeting.path)
                return (folderPath(f), folderPath(f))
            case .owner:
                if isMe(t.todo.owner, myName) { return ("0", "You") }
                return t.todo.owner.isEmpty ? ("2", "No owner") : ("1" + t.todo.owner, t.todo.owner)
            case .due:
                let group = t.dueGroup(today: today)
                return ("\(group.rawValue)", group.title)
            }
        }
        var groups: [String: Group] = [:]
        for t in list {
            let (k, label) = key(t)
            groups[k, default: Group(key: k, label: label, items: [])].items.append(t)
        }
        return groups.values.sorted { $0.key < $1.key }
    }

    @ViewBuilder private func row(_ item: TodoItem, today: Date, myName: String, showOwner: Bool) -> some View {
        if editing == item.id {
            editRow(item)
        } else if item.meeting.path.isEmpty {
            // Your own list's to-dos are only here, so they're put right here.
            todoRow(item, today: today, myName: myName, showOwner: showOwner)
                .contextMenu {
                    Button("Edit") {
                        edited = typedForm(item.todo)
                        editing = item.id
                    }
                    Button("Delete", role: .destructive) { change(item, to: nil) }
                }
        } else {
            todoRow(item, today: today, myName: myName, showOwner: showOwner)
        }
    }

    private func todoRow(_ item: TodoItem, today: Date, myName: String, showOwner: Bool) -> some View {
        let late = item.isOverdue(today: today)
        let folder = item.meeting.path.isEmpty ? "" : parentOf(item.meeting.path)
        let date = item.meeting.startedAt.map { compactDate($0) } ?? ""
        return TodoRow(todo: item.todo, alignment: homePreview ? .center : .top, tick: { tick(item) }) {
            HStack(spacing: 8) {
                if item.meeting.path.isEmpty {
                    Text("Your list").foregroundStyle(.secondary)
                } else {
                    Button {
                        model.openMeeting(item.meeting.path, jump: Jump(tab: .summary))
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(folder.isEmpty ? Color.secondary : Color.accentColor).frame(width: 6, height: 6)
                            // The meeting itself, so two to-dos with the same words from different meetings can be
                            // told apart. One line, cut in the middle, so the date at the end stays.
                            Text("\(item.meeting.title)\(date.isEmpty ? "" : " · \(date)")").lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.link)
                    .help("Open this meeting")
                }
                if !item.todo.stamp.isEmpty {
                    Chip(text: item.todo.stamp) { model.openMeeting(item.meeting.path, jump: Jump(tab: .transcript, stamp: item.todo.stamp)) }
                }
            }
            .font(.scaled(.caption1, textScale))
        } trailing: {
            // Grouped by owner, the group heading already names them. The owner and the due date
            // take the width they need (up to a limit), and the task has the rest.
            if showOwner {
                HStack(spacing: 5) {
                    if !item.todo.owner.isEmpty {
                        Avatar(name: item.todo.owner, size: 18)
                        Text(ownerLabel(item.todo.owner, myName)).lineLimit(1)
                    }
                }
                .font(.scaled(.callout, textScale))
                .frame(maxWidth: 150 * TextScale.clamped(textScale), alignment: homePreview ? .trailing : .leading)
                .fixedSize()
            }
            // Overdue says so in more than red.
            HStack(spacing: 4) {
                if late { Image(systemName: "exclamationmark.circle").accessibilityHidden(true) }
                Text(dueLabel(item, today: today)).lineLimit(1)
            }
                .accessibilityLabel(late ? "Overdue, due \(dueLabel(item, today: today))" : dueLabel(item, today: today))
                .font(.scaled(.callout, textScale)).monospacedDigit()
                .foregroundStyle(late ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(maxWidth: 112 * TextScale.clamped(textScale), alignment: .trailing)
                .fixedSize()
        }
        .font(.scaled(.body, textScale))
        .padding(.vertical, 7)
    }

    /// One of your own list's to-dos, being put right: Return saves it, Escape leaves it as it was.
    private func editRow(_ item: TodoItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24)
                .accessibilityHidden(true)
            TextField("To-do", text: $edited, prompt: Text("Send the deck - Jane - due Fri, Nov 6"))
                .textFieldStyle(.plain)
                .focused($editFocused)
                .onAppear { editFocused = true }
                .onSubmit {
                    editing = nil
                    if !edited.trimmed.isEmpty { change(item, to: typedTodo(edited, owner: model.config.myName)) }
                }
                .onExitCommand { editing = nil }
                // Clicking elsewhere leaves it as it was, as Escape does.
                .onChange(of: editFocused) { if !editFocused { editing = nil } }
        }
        .padding(.vertical, 7)
    }

    private func dueLabel(_ item: TodoItem, today: Date) -> String {
        guard let due = item.dueDate else { return "No date" }
        // Days on the calendar: a day the clocks change on is still one day.
        let d = gregorian.dateComponents([.day], from: gregorian.startOfDay(for: today), to: due).day ?? 0
        return d == 0 ? "Today" : d == 1 ? "Tomorrow" : shortDay(due, now: today)
    }

    private var addField: some View {
        HStack(spacing: 10) {
            // A plus, not a lighter circle, to tell it from a to-do's own; as wide as its checkbox.
            Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
                .accessibilityHidden(true)
            TextField("Add a to-do, then Return", text: $draft)
                .textFieldStyle(.plain)
                .font(.scaled(.body, textScale))
                .focused($addFocused)
                .help("Yours unless you name someone: Send the deck - Jane - due Fri, Nov 6")
                .onSubmit(add)
        }
    }

    /// To-dos added here go in the Meetings folder's own todo.md, owned by you unless you name someone.
    private func add() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        do {
            try model.library.addTodo("", typedTodo(text, owner: model.config.myName))
            local[""] = onDisk("")
            draft = ""
            model.toast("Added to your list")
        } catch {
            model.toast(error.localizedDescription, isError: true)
        }
    }

    /// A list as its file is now. The file is changed as it stands, never written over with what
    /// this page last read, so this is what's shown until the app has read it back too.
    private func onDisk(_ path: String) -> String? { model.library.readTodo(path) }

    private func tick(_ item: TodoItem) {
        let path = item.meeting.path
        model.library.tick(path, item.todo, undo: undoManager) { [local = $local] text in
            // nil: nothing was ticked, and the list is read again.
            withAnimation { local.wrappedValue[path] = text }
            if text != nil { model.toast("\(item.todo.done ? "Unticked" : "Ticked") in \(path.isEmpty ? "your list" : "“\(item.meeting.title)”")") }
        }
    }

    /// One of your own list's to-dos written differently, or deleted (`body` nil).
    private func change(_ item: TodoItem, to body: String?) {
        let path = item.meeting.path
        do {
            guard try model.library.editTodo(path, line: item.todo.line, text: item.todo.text, to: body) else {
                // It isn't in the file as it's shown here: nothing was changed, and the list is read again.
                withAnimation { local[path] = nil }
                return model.toast("That to-do has changed in your list since this page was read, so it wasn’t changed. The list has been read again.")
            }
            withAnimation { local[path] = onDisk(path) }
            model.toast(body == nil ? "Deleted from your list" : "Changed in your list")
        } catch {
            model.toast(error.localizedDescription, isError: true)
        }
    }
}

/**
 * One to-do as it's listed, in a meeting, on the To-dos page and Home, and on New recording: its
 * box, which ticks it, its task, a line of detail under it (`caption`) and anything beside it
 * (`trailing`). Ticking is Library.tick wherever it's done.
 */
struct TodoRow<Caption: View, Trailing: View>: View {
    let todo: Todo
    /// The task as shown, when it's more than its words (Find's marks in a meeting).
    var task: AttributedString?
    var alignment = VerticalAlignment.top
    let tick: () -> Void
    @ViewBuilder var caption: Caption
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: 10) {
            TodoCheckbox(checked: todo.done, what: todo.text, action: tick)
                .padding(.top, alignment == .top ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(task ?? AttributedString(todo.text))
                    .strikethrough(todo.done).foregroundStyle(todo.done ? .secondary : .primary).textSelection(.enabled)
                caption.font(.caption)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension TodoRow where Trailing == EmptyView {
    init(todo: Todo, task: AttributedString? = nil, alignment: VerticalAlignment = .top, tick: @escaping () -> Void, @ViewBuilder caption: () -> Caption) {
        self.init(todo: todo, task: task, alignment: alignment, tick: tick, caption: caption, trailing: { EmptyView() })
    }
}
