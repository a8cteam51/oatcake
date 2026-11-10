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
    @ViewState private var finding = false
    @ViewState private var query = ""
    @ViewState private var match = 0
    @ViewState private var copied = false
    @FocusState private var findFocused: Bool

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
        // ⌘F: Find, on the transcript.
        .onChange(of: model.findRequest) {
            flush()
            markdown = false
            Remembered.markdown = false
            switchTab(.transcript)
            finding = true
            findFocused = true
        }
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
            if markdown || status == "todo" || status == "failed" {
                HStack(spacing: 6) {
                    Text(["saving": "Saving…", "saved": "Saved", "failed": "Couldn’t save", "todo": "Saved to todo.md"][status] ?? "Saves as you type")
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
            let what = tab == .summary ? "summary and to-dos" : tab == .transcript ? "transcript" : "notes"
            Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy the \(what) as Markdown")
            ShareLink(item: shareText, subject: Text(meetingTitle(node))) { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Send the \(what) with Mail, Messages or another app")
            Button { model.reveal(path) } label: { Label("Show in Finder", systemImage: "arrow.up.forward.square") }
                .help("Show this meeting’s folder in Finder")
        }
    }

    /// What Copy and Share take: the tab you're on, as Markdown under the meeting's title and date.
    private var shareText: String {
        let part = { (key: FileKey) in forReading(files?[key] ?? "").trimmed }
        var parts = ["# \(meetingTitle(node))", metaLine]
        switch tab {
        case .summary:
            if !part(.todos).isEmpty { parts.append("## To-dos\n\n\(part(.todos))") }
            parts.append(part(.summary))
        case .transcript: parts.append(part(.transcript))
        case .notes: parts.append(part(.notes))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
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
        let rows = transcriptRows(files)
        let found = finding && tab == .transcript && !markdown ? matches(in: rows) : []
        return VStack(spacing: 0) {
            if finding && tab == .transcript && !markdown {
                findBar(found)
                Divider()
            }
            scrolling(files, rows: rows, found: found)
        }
    }

    private func scrolling(_ files: [FileKey: String], rows: [Row], found: [Int]) -> some View {
        let current = found.indices.contains(match) ? found[match] : nil
        return ScrollViewReader { proxy in
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
                        case .transcript: transcript(rows, current: current)
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
            .onChange(of: current) {
                if let current { withAnimation { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.33)) } }
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
            if summary.trimmed.isEmpty && !(files[.transcript] ?? "").trimmed.isEmpty {
                summaryLater
            } else if summary.trimmed.isEmpty {
                Text("No summary for this meeting.").foregroundStyle(.secondary)
            } else {
                MarkdownView(markdown: summary)
            }
        }
    }

    /// A meeting without its summary: it's being written now (after a save), or the model couldn't
    /// be reached and it can be written when it can.
    @ViewBuilder private var summaryLater: some View {
        if model.summarising.contains(path) {
            Notice(tone: .blue) {
                Text("Writing the summary…").fontWeight(.semibold)
                Text("The transcript and your notes are already saved.")
            }
        } else {
            let error = model.summaryErrors[path]
            Notice(tone: error == nil ? .grey : .red) {
                Text("No summary yet").fontWeight(.semibold)
                if let error {
                    ModelError(raw: error, prefix: "Couldn’t write it. ")
                } else {
                    Text("The transcript and your notes are saved. Oatcake can write the summary and to-dos from them now.")
                }
                Button("Write summary") { model.writeSummary(path) }.padding(.top, 6)
            }
        }
    }

    // MARK: Transcript

    /// A line of the transcript as shown. Granola's CSV export has transcripts without times or
    /// names: those are plain paragraphs, with no speaker.
    private struct Row {
        var speaker: String?
        var stamp = ""
        var text: String
    }

    private func transcriptRows(_ files: [FileKey: String]) -> [Row] {
        let lines = transcriptLines
        if !lines.isEmpty { return lines.map { Row(speaker: $0.speaker, stamp: $0.stamp, text: $0.text) } }
        return (files[.transcript] ?? "").components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }.map { Row(text: $0) }
    }

    /// The rows that have what's being looked for.
    private func matches(in rows: [Row]) -> [Int] {
        let wanted = query.trimmed
        guard !wanted.isEmpty else { return [] }
        return rows.indices.filter { rows[$0].text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func findBar(_ found: [Int]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(1, found) }
                .onChange(of: query) { match = 0 }
            Text(query.trimmed.isEmpty ? "" : found.isEmpty ? "Not found" : "\(min(match, found.count - 1) + 1) of \(found.count)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button { step(-1, found) } label: { Image(systemName: "chevron.up") }.disabled(found.isEmpty).help("Previous")
            Button { step(1, found) } label: { Image(systemName: "chevron.down") }.disabled(found.isEmpty).help("Next (Return)")
            Button("Done") { endFind() }.help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onKeyPress(.escape) {
            endFind()
            return .handled
        }
    }

    private func step(_ by: Int, _ found: [Int]) {
        guard !found.isEmpty else { return }
        match = (min(match, found.count - 1) + by + found.count) % found.count
    }

    private func endFind() {
        finding = false
        findFocused = false
        query = ""
        match = 0
    }

    /// The text with what's being looked for marked.
    private func marked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let wanted = query.trimmed
        guard finding, !wanted.isEmpty else { return out }
        var from = text.startIndex
        while let range = text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) {
                out[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
            }
            from = range.upperBound
        }
        return out
    }

    private func transcript(_ rows: [Row], current: Int?) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                // A long turn is several paragraphs: the ones after the first show only their time.
                let continued = i > 0 && row.speaker != nil && rows[i - 1].speaker == row.speaker
                HStack(alignment: .top, spacing: 10) {
                    if let speaker = row.speaker {
                        Avatar(name: speaker, size: 24).opacity(continued ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                if !continued { Text(speaker).fontWeight(.semibold) }
                                Text(row.stamp).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.callout)
                            Text(marked(row.text)).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        }
                    } else {
                        Text(marked(row.text)).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, continued ? 3 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == flash || i == current ? Color.orange.opacity(0.16) : .clear))
                .id(i)
            }
            if rows.isEmpty { Text("transcript.md is empty.").foregroundStyle(.secondary) }
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
