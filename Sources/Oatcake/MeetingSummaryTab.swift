import OatcakeCore
import SwiftUI

extension MeetingView {
    /// A to-do's due date as the To-dos page writes it, in the Mac's region; todo.md's own words when
    /// they aren't a date ("ASAP").
    private func dueText(_ due: String) -> String {
        let when = parseISO(meta.startedAt) ?? meetingDate(node)
        return dueDate(due, meetingDate: when).map { shortDay($0) } ?? due
    }

    func summary(_ files: [FileKey: String]) -> some View {
        let todoText = files[.todos] ?? ""
        let todos = parseTodos(todoText)
        let open = todos.filter { !$0.done }.count
        let summary = forReading(files[.summary] ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            // Turned off in Settings › General: no checklist, and nothing to say about one.
            if model.config.todosEnabled { todoList(todos, todoText: todoText, open: open) }
            if summary.trimmed.isEmpty && !(files[.transcript] ?? "").trimmed.isEmpty {
                summaryLater
            } else if summary.trimmed.isEmpty {
                Text("No summary for this meeting.").foregroundStyle(.secondary)
            } else {
                SelectableMarkdown(markdown: summary, fontSize: 14 * scale, marks: findWords, label: "Summary")
            }
        }
    }

    /// The meeting's to-dos (todo.md), to tick and add to, above its summary.
    private func todoList(_ todos: [Todo], todoText: String, open: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The summary was written but the to-dos couldn't be read from the model's reply.
            if let problem = model.jobs.todoProblems[path] {
                Notice(tone: .amber) { Text(problem) }.padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                // No to-dos yet: just the field to add one.
                if !todos.isEmpty { SectionLabel(text: "To-dos\(open > 0 ? " · \(open) open" : "")") }
                ForEach(todos, id: \.line) { t in
                    let detail = [t.owner.isEmpty ? nil : ownerLabel(t.owner, model.config.myName), t.due.isEmpty ? nil : "due \(dueText(t.due))"].compactMap { $0 }
                    // The time in the call goes on the line under the to-do, after its owner and due date, as on the To-dos page.
                    TodoRow(todo: t, task: marked(t.text), tick: { tick(t) }) {
                        if !detail.isEmpty || !t.stamp.isEmpty {
                            HStack(spacing: 8) {
                                if !detail.isEmpty { Text(detail.joined(separator: " · ")).foregroundStyle(.secondary) }
                                if !t.stamp.isEmpty { Chip(text: t.stamp) { jumpTo(t.stamp) } }
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    // A plus, not a lighter circle, to tell it from a to-do's own circle: light enough for that
                    // couldn't be seen. As wide as a to-do's checkbox, so the circles line up.
                    Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
                        .accessibilityHidden(true)
                    TextField("Add a to-do, then Return", text: $newTodo)
                        .textFieldStyle(.plain)
                        .help("Add an owner or due date with dashes: Send the deck - Jane - due Fri, Nov 6")
                        .onSubmit {
                            guard !newTodo.trimmed.isEmpty else { return }
                            let typed = typedTodo(newTodo)
                            changeTodos(shown: addTodo(todoText, typed)) { try model.library.addTodo(path, typed); return true }
                            newTodo = ""
                        }
                }
            }
            .padding(.bottom, 24)
        }
    }

    func regenerate(_ part: SummaryPart, template: SummaryTemplateChoice = .meetings) {
        // Save edits before asking for a replacement; a failed save must not discard pending text.
        flush()
        guard !model.edits.isWaiting(in: path) else { return }
        model.jobs.regenerate(part, path, template: template)
    }

    /// A meeting without its summary: it's being written now (after a save), or the model couldn't
    /// be reached and it can be written when it can.
    @ViewBuilder private var summaryLater: some View {
        if model.jobs.summarising.contains(path) {
            Notice(tone: .blue) {
                Text("Writing the summary…").fontWeight(.semibold)
                Text(model.downloads.modelDownloadStatus.map { "\($0). The summary is written as soon as it’s here; the transcript and your notes are already saved." }
                     ?? "The transcript and your notes are already saved.")
            }
        } else {
            let error = model.jobs.summaryErrors[path]
            Notice(tone: error == nil ? .grey : .red) {
                Text("No summary yet").fontWeight(.semibold)
                if let error {
                    ModelError(raw: error, prefix: "Couldn’t write it. ")
                } else {
                    Text("The transcript and your notes are saved. Oatcake can write the summary and to-dos from them now.")
                }
                HStack(spacing: 10) {
                    Button("Write summary") { model.jobs.writeSummary(path) }
                    // What stopped it is usually put right in Settings: the model, or its download.
                    if error != nil { SettingsPaneLink(pane: .models, title: "Open Settings").buttonStyle(.link) }
                }
                .padding(.top, 6)
            }
        }
    }
}
