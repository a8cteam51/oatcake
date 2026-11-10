import OatcakeCore
import SwiftUI

/// The call in progress: one note per line, each stamped with the time you started typing it.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    @FocusState private var focused: UUID?
    @ViewState private var micQuietSince: Date?
    @ViewState private var callQuietSince: Date?
    @ViewState private var devices: [InputDevice] = []
    @ViewState private var showTranscript = UserDefaults.standard.object(forKey: "liveTranscriptShown") as? Bool ?? true

    private var status: RecorderStatus { model.status }
    private var started: Bool { status.state == .recording }
    private var elapsed: Double { status.elapsed ?? 0 }
    private var lines: [LiveLine] { model.liveNotes[rec.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pathAbove(rec.folder ?? "", rec.title)).foregroundStyle(.secondary)
                    PageTitle(text: rec.title).padding(.top, 4)
                    notices
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in noteRow(line) }
                    }
                    .padding(.top, 24)
                    Text("One point per line. Each is stamped with the time you started typing it, and you can go back and edit any line.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 14)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if showTranscript && model.config.liveTranscript {
                Divider()
                transcript.frame(width: 340)
            }
          }
            Divider()
            bar
        }
        .toolbar { toolbar }
        .onAppear(perform: loadNotes)
        .onDisappear { model.saveLiveNotes(rec.id) }
        .onChange(of: status) { trackSilence() }
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
    }

    // MARK: Header

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                if started {
                    RecDot()
                    Text("Recording").foregroundStyle(.red).fontWeight(.semibold)
                    Text(clock(elapsed)).foregroundStyle(.red).monospacedDigit()
                } else {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                    Text(status.state == .error ? "Recording stopped" : "Starting…").foregroundStyle(.secondary)
                }
            }
        }
        if model.config.liveTranscript {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(get: { showTranscript }, set: { showTranscript = $0; UserDefaults.standard.set($0, forKey: "liveTranscriptShown") })) {
                    Text("Transcript")
                }
                .toggleStyle(.button)
                .help("Show or hide the live transcript")
            }
        }
        ToolbarItem(placement: .automatic) {
            // Nothing has been recorded until audio arrives, so until then it's Cancel, not Stop.
            if status.state == .starting {
                Button("Cancel") { model.cancelRecording(hasNotes: lines.contains { !$0.text.trimmed.isEmpty }) }
                    .help("Cancel this recording")
            } else {
                Button { model.confirmStop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .help("Stop recording")
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if status.state == .starting && Date().timeIntervalSince(rec.startedAt) > 6 {
            Notice(tone: .amber) {
                Text("The recorder hasn’t started yet").fontWeight(.semibold)
                Text("If macOS is asking whether OatcakeRecorder can use the microphone or record system audio, click Allow.")
            }
            .padding(.top, 16)
        }
        if status.state == .error {
            Notice(tone: .red) { Text(status.error ?? "The recorder stopped.") }.padding(.top, 16)
        }
        let now = Date()
        if let since = micQuietSince, now.timeIntervalSince(since) >= 30 {
            Notice(tone: .amber) {
                Text("Your microphone has been silent for \(Int(now.timeIntervalSince(since))) seconds").fontWeight(.semibold)
                Text("Check it isn’t muted, or switch to another microphone using the button below.")
            }
            .padding(.top, 16)
        }
        if let since = callQuietSince, now.timeIntervalSince(since) >= 30 {
            Notice(tone: .amber) {
                Text("No call audio for \(Int(now.timeIntervalSince(since))) seconds").fontWeight(.semibold)
                Text("If people are talking, allow OatcakeRecorder in System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
            .padding(.top, 16)
        }
    }

    /// Silence: a working mic always picks up some room noise; true silence means nothing arrives.
    private func trackSilence() {
        guard started else { return }
        let micQuiet = status.micDevice != nil && (status.micLevel ?? 0) < 0.001
        let callQuiet = (status.systemLevel ?? 0) < 0.001
        micQuietSince = micQuiet ? (micQuietSince ?? Date()) : nil
        callQuietSince = callQuiet ? (callQuietSince ?? Date()) : nil
    }

    // MARK: Live transcript

    /// What's been said so far, a moment after each pause. Your microphone is you; everyone on the
    /// call side shares one obviously made-up name until the call is over and the voices are told apart.
    private var transcript: some View {
        let lines = liveTranscript(model.liveLines)
        let myName = model.config.myName.isEmpty ? "You" : model.config.myName
        let other = callPlaceholder(for: rec.id)
        let stopped = model.liveStatus.hasPrefix("The live transcript stopped")
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(text: "Live transcript")
                        Spacer()
                        Text("Names come after the call").font(.caption).foregroundStyle(.secondary)
                    }
                    if lines.isEmpty && !stopped {
                        Text(["", "Listening"].contains(model.liveStatus) ? "Listening. What’s said appears here a moment after each pause." : "\(model.liveStatus)…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(line.track == .mic ? myName : other).fontWeight(.semibold)
                                    .foregroundStyle(line.track == .mic ? AnyShapeStyle(person(myName).color) : AnyShapeStyle(.secondary))
                                Text(clock(line.start)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.caption)
                            Text(line.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    if stopped { Text(model.liveStatus).font(.callout).foregroundStyle(.red) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveLines.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Notes

    /// What's saved (prep notes, or notes from before the window reopened), then a blank line.
    private func loadNotes() {
        if model.liveNotes[rec.id] == nil {
            let saved = Recordings.loadNotes(rec.id).map { LiveLine(at: $0.at, prep: $0.at == nil, text: $0.text) }
            model.liveNotes[rec.id] = saved + [LiveLine(at: nil, prep: false, text: "")]
        }
        focused = lines.last?.id
    }

    private func update(_ next: [LiveLine], focus: UUID? = nil) {
        model.liveNotes[rec.id] = next
        model.liveNotesChanged(rec.id)
        if let focus { DispatchQueue.main.async { focused = focus } }
    }

    private func noteRow(_ line: LiveLine) -> some View {
        let index = lines.firstIndex { $0.id == line.id } ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Chip(text: line.prep ? "Prep" : clock(line.at ?? (started ? elapsed : 0)),
                 style: line.prep ? .prep : line.at == nil ? .pending : .normal)
                .frame(width: 58, alignment: .leading)
            TextField(index == lines.count - 1 && line.text.isEmpty ? "Type a point, then Return" : "", text: Binding(
                get: { line.text },
                set: { text in
                    // Before audio arrives the clock hasn't started, so a line begun then is stamped 00:00:
                    // it's a note from the call, not prep. Only notes written on New recording are prep.
                    update(lines.map { l in
                        guard l.id == line.id else { return l }
                        var l = l
                        l.text = text
                        l.at = l.prep || text.isEmpty ? nil : l.at ?? (started ? elapsed.rounded(.down) : 0)
                        return l
                    })
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused, equals: line.id)
                .onSubmit { returnPressed(on: line) }
                .onKeyPress(.upArrow) { move(from: line, by: -1) }
                .onKeyPress(.downArrow) { move(from: line, by: 1) }
                .onKeyPress(.delete) {
                    guard line.text.isEmpty, lines.count > 1 else { return .ignored }
                    let i = lines.firstIndex { $0.id == line.id } ?? 0
                    let next = lines.indices.contains(i - 1) ? lines[i - 1].id : lines[min(i + 1, lines.count - 1)].id
                    update(lines.filter { $0.id != line.id }, focus: next)
                    return .handled
                }
        }
    }

    private func returnPressed(on line: LiveLine) {
        guard !line.text.trimmed.isEmpty, let i = lines.firstIndex(where: { $0.id == line.id }) else {
            focused = line.id
            return
        }
        if lines.indices.contains(i + 1), lines[i + 1].text.isEmpty {
            focused = lines[i + 1].id
            return
        }
        let added = LiveLine(at: nil, prep: false, text: "")
        var next = lines
        next.insert(added, at: i + 1)
        update(next, focus: added.id)
    }

    private func move(from line: LiveLine, by offset: Int) -> KeyPress.Result {
        guard let i = lines.firstIndex(where: { $0.id == line.id }), lines.indices.contains(i + offset) else { return .ignored }
        focused = lines[i + offset].id
        return .handled
    }

    // MARK: Bottom bar

    private var micStatus: (text: String, color: Color, warn: Bool) {
        guard started else { return (status.state == .error ? "Recording stopped." : "Starting…", .secondary, false) }
        guard let device = status.micDevice else { return ("No microphone found. Connect one to record your side of the call.", .red, true) }
        if let mic = model.config.mic, device.uid != mic.uid {
            return ("\(mic.name) isn’t connected, so this is recording from \(device.name).", .amber, true)
        }
        return ("Recording from \(device.name).", .secondary, false)
    }

    private var bar: some View {
        let mic = micStatus
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Meter(label: "You", level: status.micLevel)
                Meter(label: "Call", level: status.systemLevel)
            }
            Label(mic.text, systemImage: "mic").font(.callout).foregroundStyle(mic.color).lineLimit(2)
            Spacer()
            Menu {
                Section("Microphone") {
                    ForEach(micChoices(model.config.mic, devices), id: \.value) { choice in
                        Button {
                            model.setMic(chooseMic(choice.value, devices, current: model.config.mic))
                        } label: {
                            if (model.config.mic?.uid ?? "") == choice.value { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                        }
                    }
                }
                Divider()
                Text("Call audio is everything your Mac plays. It’s always recorded, so Oatcake can tell the voices apart.")
            } label: {
                Label(status.micDevice?.name ?? model.config.mic?.name ?? "Same as Mac", systemImage: mic.warn ? "exclamationmark.triangle" : "mic")
            }
            .fixedSize()
            .help(mic.text)
            .onTapGesture { Task { devices = (try? await Recordings.listInputs()) ?? devices } }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
