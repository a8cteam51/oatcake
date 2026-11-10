import OatcakeCore
import SwiftUI

private let effortHint = "Higher thinks longer: more careful summaries and name guesses, but slower and more usage."

/// The Settings window. Every change is saved as it's made; there's no Save button.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var devices: [InputDevice]?

    var body: some View {
        let config = model.config
        Form {
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
                Toggle(isOn: bind(\.keepAudio)) {
                    Text("Keep call audio after saving")
                    Text("When off, the audio is deleted once a meeting is saved. The transcript, notes and summary stay.")
                }
            }

            Section("Storage") {
                LabeledContent {
                    Button("Choose…") { model.chooseMeetingsFolder() }
                } label: {
                    Text("Meetings folder")
                    Text(shortPath(config.outputDir)).font(.system(.caption, design: .monospaced)).help(config.outputDir)
                }
                GranolaRow()
            }

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
            } header: {
                Text("Calendar")
            } footer: {
                Text("In Google Calendar, open Settings, pick your calendar under “Settings for my calendars”, then copy “Secret address in iCal format” from the Integrate calendar section. Without one, Upcoming is hidden.")
                    .settingsHint()
            }

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

            PeopleSection()
            llmSection
            UpdatesSection()
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 700)
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
        .onAppear {
            // The Electron version's names for the two transcription choices read as the new ones.
            let key = SpeechModels.asrChoice(model.config.asrModel).key
            if key != model.config.asrModel { model.saveConfig(with(model.config) { $0.asrModel = key }) }
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
            Picker("Provider", selection: bindLlm(\.provider)) {
                Text("Claude Code").tag(LlmProvider.claudeCode)
                Text("Anthropic API").tag(LlmProvider.anthropic)
                Text("OpenAI-compatible").tag(LlmProvider.openaiCompatible)
            }
            .pickerStyle(.segmented)
            switch llm.provider {
            case .claudeCode:
                Picker("Model", selection: bindLlm(\.claudeCode.model)) {
                    Text("Default").tag("")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                    Text("Haiku").tag("haiku")
                }
                effortPicker(bindLlm(\.claudeCode.effort))
            case .anthropic:
                VStack(alignment: .leading, spacing: 6) {
                    Text("API key")
                    SecretField(name: .anthropic, placeholder: "sk-ant-…")
                }
                Picker("Model", selection: bindLlm(\.anthropic.model)) {
                    ForEach(Array(Set(anthropicModels + [llm.anthropic.model])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                effortPicker(bindLlm(\.anthropic.effort))
            case .openaiCompatible:
                TextField(text: bindLlm(\.openai.baseUrl), prompt: Text("e.g. http://localhost:11434/v1")) {
                    Text("Endpoint")
                    if llm.openai.baseUrl.trimmed.isEmpty { Text("Required").foregroundStyle(Color.amber) }
                }
                .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 6) {
                    Text("API key ") + Text("· optional for local servers").font(.caption).foregroundStyle(.secondary)
                    SecretField(name: .openai, placeholder: "sk-…")
                }
                TextField(text: bindLlm(\.openai.model), prompt: Text("e.g. llama3.1:70b")) {
                    Text("Model")
                    if llm.openai.model.trimmed.isEmpty { Text("Required").foregroundStyle(Color.amber) }
                }
                .font(.system(.body, design: .monospaced))
                effortPicker(bindLlm(\.openai.effort))
            }
            TestRow(missing: llm.provider == .openaiCompatible && (llm.openai.baseUrl.trimmed.isEmpty || llm.openai.model.trimmed.isEmpty)
                ? "Fill in the endpoint and model first." : nil)
                .id(llm.provider)
        } header: {
            Text("Summaries and name suggestions")
        } footer: {
            Text(llmFoot(llm.provider)).settingsHint()
        }
    }

    private func llmFoot(_ provider: LlmProvider) -> String {
        switch provider {
        case .claudeCode: "Uses your Claude Code sign-in on this Mac. No API key needed."
        case .anthropic: "Billed to your Anthropic account. The key is kept in your Keychain."
        case .openaiCompatible: "Any server that speaks the OpenAI chat API, such as Ollama or LM Studio. Name suggestions need a model that follows instructions well."
        }
    }

    private func effortPicker(_ binding: Binding<Effort>) -> some View {
        LabeledContent {
            Picker("Effort", selection: binding) {
                Text("Low").tag(Effort.low)
                Text("Medium").tag(Effort.medium)
                Text("High").tag(Effort.high)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Effort")
            Text(effortHint)
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
        let llm = makeLlm(model.config.llm)
        do {
            let reply = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await llm.complete(system: "Reply with the single word OK and nothing else.", prompt: "Say OK.") }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw OatcakeError("No reply after 60 seconds")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            result = (true, "Working: replied “\(reply.trimmed.prefix(40))” in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
        } catch {
            result = (false, String(error.localizedDescription.prefix(300)))
        }
        running = false
    }
}

/// Settings › Storage › Import from Granola: the export's notes become meetings in a Granola folder.
private struct GranolaRow: View {
    @Environment(AppModel.self) private var model
    @ViewState private var running = false
    @ViewState private var text: String?
    @ViewState private var failed = false

    var body: some View {
        LabeledContent {
            Button(running ? "Importing…" : "Import…") { Task { await run() } }.disabled(running)
        } label: {
            Text("Import from Granola")
            Text(text ?? "Pick the .zip from Granola's export. Each note becomes a meeting; ones already here are skipped.")
                .foregroundStyle(failed ? Color.red : Color.secondary)
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        do {
            guard let r = try await model.importGranolaExport() else { return }
            failed = false
            text = [r.imported > 0 ? "Imported \(plural(r.imported, "meeting")) into the \(r.folder) folder." : "Nothing new to import.",
                    r.skipped > 0 ? "\(plural(r.skipped, "meeting")) already here." : nil,
                    r.unreadable > 0 ? "\(plural(r.unreadable, "row")) couldn't be read." : nil].compactMap { $0 }.joined(separator: " ")
        } catch {
            failed = true
            text = error.localizedDescription
        }
    }
}

/**
 * An API key or the calendar address. It's kept in the Keychain and never shown again, so a saved
 * one shows as a hint ("Saved · ends in 4f2a"). A new value saves on Return, on leaving the field,
 * or after a pause in typing.
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
                    .buttonStyle(.borderless).help("Show or hide what you're typing")
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
