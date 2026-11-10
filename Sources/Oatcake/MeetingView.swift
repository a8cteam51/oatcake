import OatcakeCore
import SwiftUI

/// Remembered across meetings, so you can step through meetings on the same tab and view.
@MainActor private enum Remembered {
    static var tab = MeetingTab.summary
    static var markdown = false
}

private enum FileKey: Hashable {
    case summary, transcript, notes, todos
    var file: MeetingFile {
        switch self {
        case .summary: .summary
        case .transcript: .transcript
        case .notes: .notes
        case .todos: .todo
        }
    }
}

struct MeetingView: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode
    let jump: Jump?

    @ViewState private var files: [FileKey: String]?
    @ViewState private var meta = MeetingMeta()
    @ViewState private var loadError = ""
    @ViewState private var tab = Remembered.tab
    @ViewState private var markdown = Remembered.markdown
    @ViewState private var status = ""
    @ViewState private var flash = -1
    @ViewState private var newTodo = ""
    @ViewState private var pending: [FileKey: String] = [:]
    @ViewState private var saveTask: Task<Void, Never>?
    @ViewState private var arrived = false

    private var path: String { node.path }

    var body: some View {
        Group {
            if !loadError.isEmpty {
                Text(loadError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let files {
                content(files)
            } else {
                Color.clear
            }
        }
        .toolbar { toolbar }
        .onAppear {
            if let jump { tab = jump.tab }
            load()
        }
        .onChange(of: model.diskVersion) { load() }
        .onDisappear { flush() }
        .background {
            // ⌘1–⌘3 switch tabs.
            ForEach(Array(MeetingTab.allCases.enumerated()), id: \.offset) { i, t in
                Button("") { switchTab(t) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
            }
        }
    }

    // MARK: Loading and saving

    /// A change on disk (Finder, another editor, our own save) only replaces the text when nothing
    /// typed here is still waiting to be saved.
    private func load() {
        guard pending.isEmpty else { return }
        do {
            let m = try model.readMeeting(path)
            files = [.summary: m.summary, .transcript: m.transcript, .notes: m.notes, .todos: m.todo]
            meta = m.meta
            loadError = ""
            if let stamp = jump?.stamp, !arrived {
                arrived = true
                // Arriving from the To-dos page with a time: jump there once the transcript has loaded.
                DispatchQueue.main.async { self.jumpTo(stamp) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Edits save 600 ms after the last keystroke, and straight away when leaving the meeting.
    private func write(_ key: FileKey, _ content: String, now: Bool = false) {
        files?[key] = content
        pending[key] = content
        status = now ? "todo" : "saving"
        saveTask?.cancel()
        saveTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(600)) }
            if !Task.isCancelled { flush() }
        }
    }

    private func flush() {
        saveTask?.cancel()
        for (key, content) in pending {
            do {
                try model.writeMeetingFile(path, key.file, content)
                // Typing that arrived during the save stays waiting.
                if pending[key] == content { pending.removeValue(forKey: key) }
            } catch {
                status = "failed"
                return
            }
        }
        if pending.isEmpty && status != "todo" && !status.isEmpty { status = "saved" }
        if status == "todo" {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if status == "todo" { status = "" }
            }
        }
    }

    private func switchTab(_ t: MeetingTab) {
        flush()
        tab = t
        Remembered.tab = t
    }

    private func jumpTo(_ stamp: String) {
        let t = seconds(stamp)
        var index = 0
        for (i, l) in transcriptLines.enumerated() where l.at <= t { index = i }
        flush()
        markdown = false
        Remembered.markdown = false
        switchTab(.transcript)
        flash = index
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tab", selection: Binding(get: { tab }, set: switchTab)) {
                Text("Summary").tag(MeetingTab.summary).help("⌘1")
                Text("Transcript").tag(MeetingTab.transcript).help("⌘2")
                Text("My notes").tag(MeetingTab.notes).help("⌘3")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .automatic) {
            if !status.isEmpty && (markdown || status == "todo") {
                HStack(spacing: 6) {
                    Text(["saving": "Saving…", "saved": "Saved", "failed": "Couldn’t save", "todo": "Saved to todo.md"][status] ?? "")
                        .foregroundStyle(status == "failed" ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if status == "failed" { Button("Try again") { flush() }.buttonStyle(.link) }
                }
                .font(.callout)
            }
            Picker("View", selection: Binding(get: { markdown }, set: { flush(); markdown = $0; Remembered.markdown = $0; status = "" })) {
                Text("Rendered").tag(false)
                Text("Markdown").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Button { model.reveal(path) } label: { Label("Show in Finder", systemImage: "arrow.up.forward.square") }
                .help("Show this meeting’s folder in Finder")
        }
    }

    // MARK: Content

    private var granola: Bool { meta.source == "granola" || node.granola }

    /// Granola labels your track "Microphone"; the call side carries Granola's own guesses at names.
    private var transcriptLines: [TranscriptLine] {
        parseTranscript(files?[.transcript] ?? "").map { l in
            var l = l
            if l.speaker == "Microphone" { l.speaker = model.config.myName } else if l.speaker == "System audio" { l.speaker = "Call audio" }
            return l
        }
    }

    private func content(_ files: [FileKey: String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: meta.title ?? meetingTitle(node))
                    Text(metaLine).foregroundStyle(.secondary).padding(.top, 8)
                    if granola {
                        Notice(tone: .grey) { Text(granolaNotice(files)) }.padding(.top, 14)
                    }
                    Spacer().frame(height: 22)
                    if markdown {
                        markdownEditors(files)
                    } else {
                        switch tab {
                        case .summary: summary(files)
                        case .transcript: transcript(files)
                        case .notes: notes(files)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 120)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: flash) {
                guard flash >= 0 else { return }
                withAnimation { proxy.scrollTo(flash, anchor: UnitPoint(x: 0, y: 0.33)) }
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    withAnimation { flash = -1 }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == stampScheme {
                jumpTo(String(url.absoluteString.dropFirst(stampScheme.count + 1)))
                return .handled
            }
            if let rel = meetingPath(from: url) {
                model.openMeeting(rel)
                return .handled
            }
            return url.scheme == "https" || url.scheme == "http" ? .systemAction : .discarded
        })
    }

    private var metaLine: String {
        let date = parseISO(meta.startedAt) ?? meetingDate(node)
        let length = parseISO(meta.endedAt).flatMap { end in parseISO(meta.startedAt).map { end.timeIntervalSince($0) } }
        let withWhom = (meta.participants ?? []).filter { $0 != model.config.myName }
            .map { $0.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression) }
        return [date.map { "\(weekday($0)), \(longDate($0))" }, date.map(hhmm), length.map(minutes),
                !granola && !withWhom.isEmpty ? "with \(withWhom.joined(separator: ", "))" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func granolaNotice(_ files: [FileKey: String]) -> String {
        let transcript = files[.transcript] ?? ""
        let plain = transcriptLines.isEmpty && !transcript.trimmed.isEmpty
        // The raw file: parsing turns "System audio (Alex)" into plain "Alex".
        let guessed = transcript.range(of: #"(?m)^\[[\d:]+\]\s+System audio \("#, options: .regularExpression) != nil
        let sidesOnly = transcript.range(of: #"(?m)^\[[\d:]+\]\s+System audio:"#, options: .regularExpression) != nil
        return ["Imported from Granola.",
                (files[.notes] ?? "").trimmed.isEmpty ? "It didn’t keep your notes." : nil,
                guessed ? "The names on the call side of its transcript are Granola’s own guesses."
                    : sidesOnly ? "Its transcript only tells your side of the call from everyone else’s." : nil,
                plain ? "Its transcript doesn’t say who said what." : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func markdownEditors(_ files: [FileKey: String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(tab == .summary ? [FileKey.todos, .summary] : [tab == .transcript ? .transcript : .notes], id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(folderPath(path)) › \(key.file.rawValue)", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { files[key] ?? "" }, set: { write(key, $0) }))
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollDisabled(true)
                        .frame(minHeight: key == .todos ? 70 : 300)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
                        .overlay(alignment: .topLeading) {
                            if key == .todos && (files[key] ?? "").isEmpty {
                                Text("- [ ] What to do — Owner — due Fri, Oct 30 — [12:34]")
                                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                            }
                        }
                }
            }
        }
    }

    private func summary(_ files: [FileKey: String]) -> some View {
        let todoText = files[.todos] ?? ""
        let todos = parseTodos(todoText)
        let open = todos.filter { !$0.done }.count
        let summary = forReading(files[.summary] ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // No to-dos yet: just the field to add one.
                if !todos.isEmpty { SectionLabel(text: "To-dos\(open > 0 ? " · \(open) open" : "")") }
                ForEach(todos, id: \.line) { t in
                    HStack(alignment: .top, spacing: 10) {
                        TodoCheckbox(checked: t.done) { write(.todos, toggleTodo(todoText, line: t.line), now: true) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.text).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary).textSelection(.enabled)
                            let detail = [t.owner.isEmpty ? nil : ownerLabel(t.owner, model.config.myName), t.due.isEmpty ? nil : "due \(t.due)"].compactMap { $0 }
                            if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if !t.stamp.isEmpty { Chip(text: t.stamp) { jumpTo(t.stamp) } }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.quaternary)
                    TextField("Add a to-do, then Return", text: $newTodo)
                        .textFieldStyle(.plain)
                        .help("Add an owner or due date with dashes: Send the deck - Alex - due Fri, Nov 6")
                        .onSubmit {
                            guard !newTodo.trimmed.isEmpty else { return }
                            write(.todos, addTodo(todoText, typedTodo(newTodo)), now: true)
                            newTodo = ""
                        }
                }
            }
            .padding(.bottom, 24)
            if summary.trimmed.isEmpty {
                Text("No summary for this meeting.").foregroundStyle(.secondary)
            } else {
                MarkdownView(markdown: summary)
            }
        }
    }

    private func transcript(_ files: [FileKey: String]) -> some View {
        let lines = transcriptLines
        let plain = lines.isEmpty ? (files[.transcript] ?? "").components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty } : []
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: l.speaker, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(l.speaker).fontWeight(.semibold)
                            Text(l.stamp).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.callout)
                        Text(l.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == flash ? Color.orange.opacity(0.16) : .clear))
                .id(i)
            }
            // Granola's CSV export has transcripts without times or names: shown as plain paragraphs.
            ForEach(Array(plain.enumerated()), id: \.offset) { _, p in
                Text(p).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).padding(.bottom, 8)
            }
            if lines.isEmpty && plain.isEmpty { Text("transcript.md is empty.").foregroundStyle(.secondary) }
        }
    }

    private func notes(_ files: [FileKey: String]) -> some View {
        let notes = parseNotes(files[.notes] ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Chip(text: n.stamp ?? "Prep", style: n.stamp == nil ? .prep : .normal)
                    Text(n.text).textSelection(.enabled)
                }
            }
            if notes.isEmpty {
                Text(granola ? "No notes. Granola didn’t keep your notes when this meeting was imported." : "You didn’t take notes in this meeting.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
