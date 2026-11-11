import OatcakeCore
import SwiftUI

/// The Settings window, in panes. Every change is saved as it's made; there's no Save button.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var devices: [InputDevice]?
    @ViewState private var jargon = ""
    @ViewState private var instructions = ""
    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            Form { general }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            Form { calendar }.formStyle(.grouped).tabItem { Label("Calendar", systemImage: "calendar") }.tag("calendar")
            Form { PeopleSection() }.formStyle(.grouped).tabItem { Label("People", systemImage: "person.2") }.tag("people")
            Form { transcription }.formStyle(.grouped).tabItem { Label("Transcription", systemImage: "waveform") }.tag("transcription")
            Form { llmSection; reasoningSection; instructionsSection; jargonSection }.formStyle(.grouped).tabItem { Label("Summaries", systemImage: "text.alignleft") }.tag("summaries")
            Form { storage }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "folder") }.tag("storage")
            Form { UpdatesSection() }.formStyle(.grouped).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
        }
        .frame(width: 620, height: 600)
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
        .onAppear {
            jargon = model.config.jargon.joined(separator: ", ")
            instructions = model.config.summaryTask
            // The Electron version's names for the two transcription choices read as the new ones.
            let key = SpeechModels.asrChoice(model.config.asrModel).key
            if key != model.config.asrModel { model.saveConfig(with(model.config) { $0.asrModel = key }) }
        }
    }

    @ViewBuilder private var general: some View {
        let config = model.config
        Section("You") {
            TextField("Your name", text: bind(\.myName))
            Text("Labels your microphone track in every transcript.").settingsHint()
        }

        Section("Recording") {
            LabeledContent("Microphone") { MicPicker(devices: devices ?? []).frame(width: 270) }
            if let devices {
                let hint = micHint(config.mic, devices)
                Text(hint.text).settingsHint(hint.color)
            }
            Toggle(isOn: bind(\.liveTranscript)) {
                Text("Live transcript")
                Text("Shows what’s being said beside your notes during the call. It’s transcribed on your Mac; who said what on the call side is worked out afterwards.")
            }
        }

        Section {
            Toggle(isOn: bind(\.callNotice)) {
                Text("Offer to record when a call starts")
                Text("A notification with a Start recording button when a calling app or browser starts using your microphone.")
            }
            Toggle(isOn: bind(\.autoStop)) {
                Text("Stop recording when the call ends")
                Text("Once the calling app has let go of your microphone and the call audio has been quiet for 15 seconds.")
            }
        } header: {
            Text("Calls")
        } footer: {
            Text("Oatcake notices a call by which apps have the microphone open. It doesn’t listen until you record.").settingsHint()
        }

    }

    @ViewBuilder private var storage: some View {
        Section("Storage") {
            LabeledContent {
                Button("Choose…") { model.chooseMeetingsFolder() }
            } label: {
                Text("Meetings folder")
                Text(shortPath(model.config.outputDir)).font(.system(.caption, design: .monospaced)).help(model.config.outputDir)
            }
            Toggle(isOn: bind(\.keepAudio)) {
                Text("Keep call audio after saving")
                Text("When off, the audio is deleted once a meeting is saved. The transcript, notes and summary stay.")
            }
        }
        Section("Import") {
            ImportRow(source: "Granola", hint: "Pick the .zip from Granola’s export. Each note becomes a meeting; ones already here are skipped.",
                      pick: model.importGranolaExport)
            ImportRow(source: "Quill", hint: "Pick the .zip from Quill’s backup. Each meeting becomes a meeting, with its recording; ones already here are skipped.",
                      pick: model.importQuillBackup)
        }
    }

    @ViewBuilder private var calendar: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Private iCal address")
                SecretField(name: .calendar, placeholder: "https://calendar.google.com/calendar/ical/…/basic.ics")
                Text(calendarStatus).settingsHint(model.calendar?.error != nil ? .red : .secondary)
            }
            Toggle(isOn: bind(\.callReminders)) {
                Text("Remind me before calls")
                Text("5 minutes before each call, a notification with a button that opens the call and starts recording, ready for notes.")
            }
            Toggle(isOn: bind(\.menuBarNextCall)) {
                Text("Show my next call in the menu bar")
                Text("The time until it starts, with what’s coming up in its menu. Oatcake then stays in the menu bar when its window is closed.")
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("In Google Calendar, open Settings, pick your calendar under “Settings for my calendars”, then copy “Secret address in iCal format” from the Integrate calendar section. Without one, Upcoming is hidden.")
                .settingsHint()
        }
    }

    @ViewBuilder private var transcription: some View {
        Section {
            Picker("Speech to text", selection: bind(\.asrModel)) {
                ForEach(SpeechModels.asr, id: \.key) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title)
                        Text(choice.detail).settingsHint()
                    }
                    .tag(choice.key)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } header: {
            Text("Transcription")
        } footer: {
            Text("Runs on your Mac. Audio never leaves it for transcription.").settingsHint()
        }
    }

    /// Typed as one comma-separated line; kept as a list.
    @ViewBuilder private var jargonSection: some View {
        Section {
            TextField("Jargon", text: $jargon, prompt: Text("Automattic, WooCommerce, Jetpack"), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
                .onChange(of: jargon) {
                    let terms = jargon.split(whereSeparator: { $0 == "," || $0.isNewline }).map { String($0).trimmed }.filter { !$0.isEmpty }
                    if terms != model.config.jargon { model.saveConfig(with(model.config) { $0.jargon = terms }) }
                }
        } header: {
            Text("Jargon")
        } footer: {
            Text("Names, products and acronyms, separated by commas. Summaries, to-dos, name suggestions and answers spell them as written here. Transcripts keep what the speech model heard.")
                .settingsHint()
        }
    }

    private func bind<T>(_ path: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: path] }, set: { value in model.saveConfig(with(model.config) { $0[keyPath: path] = value }) })
    }

    private func bindLlm<T>(_ path: WritableKeyPath<LlmConfig, T>) -> Binding<T> {
        bind((\Config.llm).appending(path: path))
    }

    /// "~/Documents/…/Meetings": long paths lose their middle; hover shows the full path.
    private func shortPath(_ full: String) -> String {
        let p = full.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
        return p.count <= 46 ? p : "\(p.prefix(20))…\(p.suffix(24))"
    }

    private var calendarStatus: String {
        guard let calendar = model.calendar else { return "Not set up — Upcoming is hidden." }
        if model.calendarFetching { return "Fetching…" }
        if let error = calendar.error {
            return calendar.updatedAt != nil ? "Last fetch failed: \(error.replacingOccurrences(of: "Couldn't update the calendar: ", with: ""))" : error
        }
        if let updated = parseISO(calendar.updatedAt) {
            let upcoming = calendar.events.filter { $0.endDate > Date() }.count
            return "Updated \(hhmm(updated)) · \(upcoming) upcoming event\(upcoming == 1 ? "" : "s")"
        }
        return "Fetching…"
    }

    @ViewBuilder private var llmSection: some View {
        let llm = model.config.llm
        Section {
            Picker("Language model", selection: bindLlm(\.model)) {
                ForEach(LocalModels.all) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title + (choice == LocalModels.recommended() ? " · recommended for this Mac" : ""))
                        Text(choice.detail).settingsHint()
                        if !LocalModels.fits(choice) {
                            Text("This Mac has \(Int(LocalModels.physicalMemory.rounded())) GB of memory, which is too little for it.").settingsHint(.amber)
                        }
                    }
                    .tag(choice.id)
                }
                VStack(alignment: .leading) {
                    Text("A model server of my own")
                    Text("Ollama, LM Studio or another server with the same chat API, on this Mac or your own network.").settingsHint()
                }
                .tag(LlmConfig.ownServer)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let chosen = LocalModels.find(llm.model) {
                ModelRow(chosen: chosen)
            } else {
                TextField(text: bindLlm(\.own.baseUrl), prompt: Text("e.g. http://localhost:11434/v1")) {
                    Text("Endpoint").font(.body)
                    if llm.own.baseUrl.trimmed.isEmpty {
                        Text("Required").font(.callout).foregroundStyle(Color.amber)
                    } else if !isLocalEndpoint(llm.own.baseUrl) {
                        Text("Has to be on this Mac or your network").font(.callout).foregroundStyle(Color.amber)
                    }
                }
                .font(.system(.body, design: .monospaced))
                TextField(text: bindLlm(\.own.model), prompt: Text("e.g. qwen3:14b")) {
                    Text("Model").font(.body)
                    if llm.own.model.trimmed.isEmpty { Text("Required").font(.callout).foregroundStyle(Color.amber) }
                }
                .font(.system(.body, design: .monospaced))
            }
            TestRow(missing: testBlocker(llm)).id(llm.model)
        } header: {
            Text("Language model")
        } footer: {
            Text("Writes summaries and to-dos, suggests names and answers questions. It runs on this Mac, and nothing from your calls is sent anywhere. A summary takes a little while to write; the transcript and your notes are saved first.")
                .settingsHint()
        }
    }

    /// Whether the model thinks each task through first. For Oatcake's own models: a server of yours
    /// decides for itself.
    @ViewBuilder private var reasoningSection: some View {
        if LocalModels.find(model.config.llm.model) != nil {
            Section {
                Toggle("Summaries", isOn: bindLlm(\.reasoning.summary))
                Toggle("To-dos", isOn: bindLlm(\.reasoning.todos))
                Toggle("Name suggestions", isOn: bindLlm(\.reasoning.names))
                Toggle("Ask", isOn: bindLlm(\.reasoning.ask))
            } header: {
                Text("Reasoning")
            } footer: {
                Text("With reasoning on, the model thinks a task through before it replies. That takes longer and isn’t always better. When Oatcake was tested, summaries gave decisions to the right person more reliably with it, names were made up less often and answers kept to the question, but to-dos lost detail. So it starts on for everything except to-dos.")
                    .settingsHint()
            }
        }
    }

    /// Why Test can't be pressed yet, if it can't.
    private func testBlocker(_ llm: LlmConfig) -> String? {
        let _ = model.modelsVersion
        if let chosen = LocalModels.find(llm.model) { return LocalModels.isDownloaded(chosen) ? nil : "Download the model first." }
        if llm.own.baseUrl.trimmed.isEmpty || llm.own.model.trimmed.isEmpty { return "Fill in the endpoint and model first." }
        return isLocalEndpoint(llm.own.baseUrl) ? nil : "The endpoint has to be on this Mac or your own network."
    }

    /// What the model is told when it writes a summary. Yours to change; Oatcake's own comes back with one button.
    @ViewBuilder private var instructionsSection: some View {
        Section {
            TextEditor(text: $instructions)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Summary instructions")
                .onChange(of: instructions) {
                    // Oatcake's own wording is kept as "none of your own", so a later improvement to it reaches you.
                    let custom = instructions.trimmed == defaultSummaryInstructions.trimmed ? "" : instructions
                    if custom != model.config.summaryInstructions { model.saveConfig(with(model.config) { $0.summaryInstructions = custom }) }
                }
            LabeledContent {
                Button("Restore Default") { instructions = defaultSummaryInstructions }
                    .disabled(instructions.trimmed == defaultSummaryInstructions.trimmed)
            } label: {
                Text(model.config.summaryInstructions.trimmed.isEmpty ? "Oatcake’s own instructions" : "Your instructions")
                Text("Used for summaries written from now on.")
            }
        } header: {
            Text("Summary instructions")
        } footer: {
            Text("What the model is told to write once it has read the transcript. Change the headings, the level of detail or the language to suit you. To-dos are collected separately and aren’t affected.")
                .settingsHint()
        }
    }
}

func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

private extension Text {
    func settingsHint(_ color: Color = .secondary) -> some View {
        font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings › Test: one short request to the chosen model, with the result underneath.
private struct TestRow: View {
    @Environment(AppModel.self) private var model
    let missing: String?
    @ViewState private var running = false
    @ViewState private var result: (ok: Bool, detail: String)?

    var body: some View {
        LabeledContent {
            Button(running ? "Testing…" : "Test") { Task { await test() } }.disabled(running || missing != nil)
        } label: {
            Text("Check it works")
            Text(missing ?? (running ? "Asking the model for a one-word reply…" : result?.detail ?? "Sends one short request with these settings."))
                .foregroundStyle(result?.ok == false && missing == nil ? Color.red : Color.secondary)
        }
    }

    private func test() async {
        running = true
        let started = Date()
        let llm = model.config.llm
        do {
            let reply = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // A one-word reply needs no reasoning. Loading the model is most of the wait.
                    try await withModel(llm, tokens: 100) { chat, _ in
                        try await chat.complete([ChatMessage("system", "Reply with the single word OK and nothing else."), ChatMessage("user", "Say OK.")],
                                                think: false, maxTokens: 20)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw OatcakeError("No reply after two minutes")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            result = (true, "Working: replied “\(reply.trimmed.prefix(40))” in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
        } catch {
            result = (false, String(explainModelError(error.localizedDescription).prefix(300)))
        }
        running = false
    }
}

/// Settings › Summaries: whether the chosen model is on this Mac, with its download or removal.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let chosen: LocalModel
    @ViewState private var removing = false

    var body: some View {
        let _ = model.modelsVersion
        if let fraction = model.modelDownloads[chosen.id] {
            LabeledContent {
                Button("Stop") { model.stopModelDownload(chosen) }
            } label: {
                Text("Downloading \(chosen.title)")
                ProgressView(value: fraction).accessibilityLabel("Download progress")
                Text("\(Int(fraction * 100))% of \(chosen.downloadSize). It carries on from here if it’s stopped.")
            }
        } else if LocalModels.isDownloaded(chosen) {
            LabeledContent {
                Button("Remove…") { removing = true }
            } label: {
                Text("\(chosen.title) is on this Mac")
                Text("\(chosen.downloadSize), in Oatcake’s own folder.")
            }
            .alert("Remove \(chosen.title)?", isPresented: $removing) {
                Button("Remove", role: .destructive) { model.removeModel(chosen) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(chosen.downloadSize). It’s downloaded again the next time it’s needed.")
            }
        } else {
            let error = model.modelDownloadErrors[chosen.id]
            LabeledContent {
                Button(error == nil ? "Download Now" : "Try Again") { model.downloadModel(chosen) }
            } label: {
                Text("\(chosen.title) isn’t downloaded yet")
                Text(error ?? "\(chosen.downloadSize), from Hugging Face. It downloads by itself during your first call, or when it’s first needed.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
        }
    }
}

/// Settings › Storage › Import from Granola or Quill: the export's meetings go into a folder named after it.
private struct ImportRow: View {
    let source: String
    let hint: String
    let pick: (@escaping ImportProgress) async throws -> ImportResult?
    @ViewState private var running = false
    /// Meetings handled and how many there are: set once a file is picked, 0 of 0 until the export has been read.
    @ViewState private var progress: (done: Int, total: Int)?
    @ViewState private var text: String?
    @ViewState private var failed = false

    var body: some View {
        LabeledContent {
            Button(running ? "Importing…" : "Import…") { Task { await run() } }.disabled(running)
        } label: {
            Text("Import from \(source)")
            if running, let progress, progress.total == 0 {
                ProgressView { Text("Reading the export…").foregroundStyle(.secondary) }.progressViewStyle(.linear)
            } else if running, let progress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("Importing \(progress.done) of \(progress.total) meetings…").foregroundStyle(.secondary)
                }
            } else {
                Text(text ?? hint)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
    }

    private func run() async {
        running = true
        defer { running = false; progress = nil }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        do {
            // On the main queue, in order, as the import reports from its background task.
            guard let r = try await pick({ done, total in DispatchQueue.main.async { progress = (done, total) } }) else { return }
            failed = false
            text = [r.imported > 0 ? "Imported \(plural(r.imported, "meeting")) into the \(r.folder) folder." : "Nothing new to import.",
                    r.skipped > 0 ? "\(plural(r.skipped, "meeting")) already here." : nil,
                    r.unreadable > 0 ? "\(plural(r.unreadable, "meeting")) couldn't be read." : nil].compactMap { $0 }.joined(separator: " ")
        } catch {
            failed = true
            text = error.localizedDescription
        }
    }
}

/**
 * The calendar's private address. It's kept in the Keychain and never shown again, so a saved one
 * shows as a hint ("Saved · calendar.google.com"). A new value saves on Return, on leaving the
 * field, or after a pause in typing.
 */
private struct SecretField: View {
    @Environment(AppModel.self) private var model
    let name: SecretName
    let placeholder: String
    @ViewState private var draft = ""
    @ViewState private var shown = false
    @ViewState private var described = (saved: false, hint: "")
    @ViewState private var pause: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if shown {
                    TextField("", text: $draft, prompt: Text(prompt))
                } else {
                    SecureField("", text: $draft, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity)
            .focused($focused)
            .help(described.saved ? "Paste a new one to replace it" : "")
            .onSubmit { save(done: true) }
            .onChange(of: draft) {
                pause?.cancel()
                let value = draft
                pause = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if !Task.isCancelled, value == draft { save(done: false) }
                }
            }
            .onChange(of: focused) { if !focused { save(done: true) } }
            // A saved one can't be shown, so the eye only appears while typing a new one.
            if !draft.isEmpty {
                Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help("Show or hide what you're typing").accessibilityLabel(shown ? "Hide what you’re typing" : "Show what you’re typing")
            }
            if described.saved {
                Button("Remove") {
                    model.setSecret(name, "")
                    draft = ""
                    load()
                }
                .help("Delete the saved one")
            }
        }
        .onAppear(perform: load)
    }

    private var prompt: String { described.saved ? described.hint : described.hint.isEmpty ? placeholder : described.hint }

    private func load() { described = Secrets.describe(name) }

    private func save(done: Bool) {
        pause?.cancel()
        guard !draft.trimmed.isEmpty else { return }
        model.setSecret(name, draft)
        if done { draft = "" }
        load()
    }
}

/// Settings › People: the voices Oatcake recognises, to rename or forget.
private struct PeopleSection: View {
    @ViewState private var voices: [KnownVoice] = []
    @ViewState private var renaming: KnownVoice?
    @ViewState private var forgetting: KnownVoice?
    @ViewState private var draft = ""
    @ViewState private var error = ""

    var body: some View {
        Section {
            if voices.isEmpty {
                Text("Nobody yet. Names you confirm in Who’s who are remembered here.").settingsHint()
            }
            ForEach(voices) { voice in
                LabeledContent {
                    HStack {
                        Button("Rename…") {
                            draft = voice.name
                            renaming = voice
                        }
                        Button("Forget…") { forgetting = voice }
                    }
                } label: {
                    Text(voice.name)
                    Text(detail(voice))
                }
            }
            if !error.isEmpty { Text(error).settingsHint(.red) }
        } header: {
            Text("People")
        } footer: {
            Text("Oatcake recognises these voices on calls. Renaming changes the name it uses from now on; meetings already saved keep the name they were saved with. Renaming someone to a name that’s already here makes them one person.")
                .settingsHint()
        }
        .onAppear(perform: load)
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { if let voice = renaming { change { try renameVoice(voice.name, to: draft) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let voice = renaming, draft.trimmed != voice.name, voices.contains(where: { $0.name == draft.trimmed }) {
                Text("\(draft.trimmed) is already here: the two become one person.")
            }
        }
        .alert("Forget \(forgetting?.name ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let voice = forgetting { change { try forgetVoice(voice.name) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Oatcake won’t recognise their voice or suggest their name any more. Meetings already saved aren’t changed.")
        }
    }

    private func load() { voices = knownVoices() }

    private func change(_ work: () throws -> Void) {
        do {
            try work()
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
        load()
    }

    private func detail(_ voice: KnownVoice) -> String {
        if voice.calls == 0 { return "Recognised again after the next call you save with them" }
        let calls = "From \(voice.calls) call\(voice.calls == 1 ? "" : "s")"
        return voice.lastSaved.map { "\(calls) · last \(shortDate($0))" } ?? calls
    }
}

/// Settings › Updates: this version, Check Now, and the newer release when there is one.
private struct UpdatesSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var copied = false

    var body: some View {
        let u = model.updater
        Section("Updates") {
            LabeledContent {
                Button("Check Now") { Task { await u.check() } }.disabled(u.checking || u.installing != nil)
            } label: {
                Text("Oatcake \(u.current)")
                Text(u.error ?? status(u)).foregroundStyle(u.error != nil ? Color.red : Color.secondary)
            }
            if let available = u.available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's new in \(available.version)")
                    if !available.notes.isEmpty {
                        Text(available.notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let blocked = u.blocked {
                        Text(blocked).font(.callout).foregroundStyle(Color.amber)
                        if let command = u.command {
                            HStack {
                                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.fill))
                                Button(copied ? "Copied" : "Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                    copied = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        copied = false
                                    }
                                }
                            }
                        }
                    } else {
                        HStack {
                            Button(u.installing ?? "Install and Relaunch") { Task { await u.install() } }
                                .buttonStyle(.borderedProminent).disabled(u.installing != nil)
                            Text("\(Int((Double(available.size) / 1e6).rounded())) MB download. Oatcake quits and reopens.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Toggle(isOn: Binding(get: { model.config.updateCheck }, set: { v in model.saveConfig(with(model.config) { $0.updateCheck = v }) })) {
                Text("Check for updates automatically")
                Text("Once a day. Nothing is installed until you choose to.")
            }
        }
    }

    private func status(_ u: Updater) -> String {
        if u.checking { return "Checking…" }
        if let available = u.available { return "Oatcake \(available.version) is available." }
        if let checked = u.checkedAt { return "Up to date · checked at \(hhmm(checked))" }
        return "Not checked yet."
    }
}
