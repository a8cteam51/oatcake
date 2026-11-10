import AVFoundation
import OatcakeCore
import SwiftUI

/// "October 29th, 2026 · 16:30 · 32 min" for a recording.
func recordingMeta(_ rec: Recording) -> String {
    [longDate(rec.startedAt), hhmm(rec.startedAt), rec.endedAt.map { minutes($0.timeIntervalSince(rec.startedAt)) }]
        .compactMap { $0 }.joined(separator: " · ")
}

/// The failure in plain words; the raw message stays behind "Details".
private func explain(_ error: String) -> String {
    let e = error.lowercased()
    if e.contains("json") || e.contains("couldn’t be read") || e.contains("data couldn") { return "Its recording details couldn’t be read. The files may be damaged or incomplete." }
    if e.contains("no such file") || e.contains("doesn’t exist") { return "Some of its audio files are missing." }
    if e.contains("model") || e.contains("download") || e.contains("network") || e.contains("internet") {
        return "The speech models couldn’t be loaded. Check your internet connection, then try again."
    }
    if e.contains("code ") { return "The processing helper stopped unexpectedly. Trying again usually works." }
    return "Something went wrong while processing this recording. Trying again usually works."
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    @ViewState private var details = false

    var body: some View {
        let progress = model.progress[rec.id]
        let step = progress?.step ?? "Starting"
        let n = stepNumber(step)
        let within = progress?.fraction ?? (analysisSteps.contains(step) ? 0.5 : 0.1)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pathAbove(rec.folder ?? "", rec.title)).font(.callout).foregroundStyle(.secondary)
                Text(rec.title).font(.title2.weight(.semibold))
                Text(recordingMeta(rec)).font(.callout).foregroundStyle(.secondary)
            }
            if let error = progress?.error {
                Notice(tone: .red) {
                    Text("Couldn’t finish “\(analysisSteps.contains(step) ? step : "Getting the recording ready")”").fontWeight(.semibold)
                    HStack(spacing: 4) {
                        Text(explain(error))
                        Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(.link)
                    }
                    if details { Text(error).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 4) }
                }
                HStack {
                    Button("Try again") { model.retry(rec) }.buttonStyle(.borderedProminent)
                    Button("Discard…") { model.discard(rec) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(step)…")
                        Spacer()
                        Text("Step \(n) of 5").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    ProgressView(value: (Double(n - 1) + within) / 5)
                }
                Text("An hour-long call takes a minute or two. You can keep working — it’ll wait under Needs review.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                (Text(progress?.error != nil ? "Couldn’t finish" : "Processing").fontWeight(.semibold) + Text(" · \(rec.title)").foregroundStyle(.secondary)).lineLimit(1)
            }
            if progress?.error == nil {
                ToolbarItem(placement: .automatic) { Button("Discard…") { model.discard(rec) } }
            }
        }
    }
}

/// Plays the review screen's clips, one at a time.
@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    var playing: String?
    var fraction = 0.0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ file: String) {
        player?.stop()
        timer?.invalidate()
        if playing == file {
            playing = nil
            return
        }
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: file)) else { return }
        p.delegate = self
        player = p
        playing = file
        fraction = 0
        p.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let p = self.player, p.duration > 0 else { return }
                self.fraction = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.playing = nil
        }
    }
}

/// Who's who: one card per voice, to name, merge or mark as mixed before saving.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording

    struct Voice: Equatable {
        var name: String
        var mixed = false
        /// Merged into another voice (`me` for your microphone).
        var into: String?
    }

    @ViewState private var analysis: Analysis?
    @ViewState private var people: [String] = []
    @ViewState private var voices: [String: Voice] = [:]
    @ViewState private var showTranscript = false
    @ViewState private var saving = false
    @ViewState private var error = ""
    @ViewState private var player = ClipPlayer()

    var body: some View {
        Group {
            if let analysis {
                HStack(spacing: 0) {
                    ScrollView { cards(analysis).padding(.horizontal, 36).padding(.vertical, 28).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity) }
                    if showTranscript {
                        Divider()
                        transcript(analysis).frame(width: 340)
                    }
                }
                .toolbar { toolbar(analysis) }
            } else {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onDisappear { player.stop() }
    }

    private func load() {
        do {
            let a = try loadAnalysis(rec)
            analysis = a
            people = knownPeople()
            voices = Dictionary(uniqueKeysWithValues: a.speakers.map { ($0.id, Voice(name: $0.suggestion?.name ?? "")) })
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var myName: String { model.config.myName.isEmpty ? "You" : model.config.myName }

    private func label(_ analysis: Analysis, _ id: String) -> String { voiceLabel(analysis, id) }

    /// The name a line will be saved under, following merges.
    private func nameOf(_ analysis: Analysis, _ id: String, _ seen: Set<String> = []) -> String {
        if id == me { return myName }
        guard let v = voices[id] else { return "Unknown" }
        if let into = v.into, !seen.contains(id) { return nameOf(analysis, into, seen.union([id])) }
        return v.mixed ? "Several people" : v.name.trimmed.isEmpty ? label(analysis, id) : v.name.trimmed
    }

    @ToolbarContentBuilder private func toolbar(_ analysis: Analysis) -> some ToolbarContent {
        let unnamed = analysis.speakers.filter { voices[$0.id]?.into == nil && voices[$0.id]?.mixed == false && (voices[$0.id]?.name.trimmed.isEmpty ?? true) }.count
        ToolbarItem(placement: .principal) {
            (Text("Who’s who").fontWeight(.semibold) + Text(" · \(rec.title)").foregroundStyle(.secondary)).lineLimit(1)
        }
        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $showTranscript) { Text("Transcript") }.toggleStyle(.button)
            Button("Discard…") { model.discard(rec) }.disabled(saving)
            if unnamed > 0 && !saving {
                Text("\(unnamed) voice\(unnamed == 1 ? "" : "s") unnamed").font(.callout).foregroundStyle(.secondary)
                    .help("Unnamed voices are saved as “Voice 1”, “Voice 2”…")
            }
            Button("Save") { save(analysis) }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
                .help("Save names and write the summary")
        }
    }

    private func cards(_ analysis: Analysis) -> some View {
        let visible = analysis.speakers.filter { voices[$0.id]?.into == nil }
        let meTalk = analysis.me?.seconds ?? analysis.lines.filter { $0.speaker == me }.reduce(0) { $0 + $1.end - $1.start }
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pathAbove(rec.folder ?? "", rec.title)).foregroundStyle(.secondary)
                PageTitle(text: rec.title, size: 22)
                Text(recordingMeta(rec)).foregroundStyle(.secondary)
                Text("Check who’s who before saving. Names label the transcript, and Oatcake remembers these voices next time.")
                    .foregroundStyle(.secondary).padding(.top, 8)
            }
            if saving, let step = model.saveStep[rec.id] {
                Notice(tone: .blue) { Text(step == "Saving voiceprints" || step == "Saving" ? "Saving…" : "\(step)…") }
            }
            if !error.isEmpty { Notice(tone: .red) { Text(error) } }
            if analysis.speakers.isEmpty {
                Notice(tone: .amber) {
                    Text("No other voices were heard").fontWeight(.semibold)
                    Text("Only your microphone picked anything up. If people were talking on the call, check that OatcakeRecorder is allowed in System Settings › Privacy & Security › Screen & System Audio Recording.")
                }
            }
            ForEach(analysis.warnings, id: \.self) { w in Notice(tone: .amber) { Text(w) } }

            card {
                HStack(spacing: 10) {
                    Avatar(name: myName, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(myName) · your microphone").fontWeight(.semibold)
                        Text("\(minutes(meTalk)) talking").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let quotes = analysis.me?.quotes, !quotes.isEmpty { clips(quotes) }
                Text("Labelled with your name from Settings.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(visible, id: \.id) { s in voiceCard(analysis, s, visible: visible) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
    }

    private func voiceCard(_ analysis: Analysis, _ s: SpeakerInfo, visible: [SpeakerInfo]) -> some View {
        let v = voices[s.id] ?? Voice(name: "")
        let shown = v.mixed ? "Several people" : v.name.trimmed.isEmpty ? label(analysis, s.id) : v.name.trimmed
        let absorbed = analysis.speakers.filter { voices[$0.id]?.into == s.id }
        let fromSuggestion = s.suggestion.map { v.name == $0.name && !v.mixed } ?? false
        let targets = visible.filter { $0.id != s.id && voices[$0.id]?.mixed != true }
        return card {
            HStack(spacing: 10) {
                Avatar(name: shown, size: 30, remember: false, color: v.mixed ? Color(nsColor: .systemGray) : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown).fontWeight(.semibold)
                    Text("\(v.name.trimmed.isEmpty && !v.mixed ? "" : "\(label(analysis, s.id)) · ")\(minutes(s.seconds)) talking")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Merge into another voice (or you), or mark as mixed.
                Menu {
                    if !v.mixed {
                        Menu("Merge with") {
                            Button("\(myName) (your microphone)") { voices[s.id]?.into = me }
                            ForEach(targets, id: \.id) { o in
                                Button(voices[o.id].map { $0.name.trimmed.isEmpty ? label(analysis, o.id) : $0.name.trimmed } ?? label(analysis, o.id)) {
                                    voices[s.id]?.into = o.id
                                }
                            }
                        }
                    }
                    Button(v.mixed ? "Not mixed" : "Mark as mixed (several people)") { voices[s.id]?.mixed.toggle() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Merge or mark as mixed")
            }
            clips(s.quotes)
            if !v.mixed {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Who is this?", text: Binding(get: { voices[s.id]?.name ?? "" }, set: { voices[s.id]?.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .textInputSuggestions {
                            ForEach(people.filter { p in let typed = v.name.trimmed.lowercased(); return !typed.isEmpty && p.lowercased().contains(typed) && p != v.name }, id: \.self) {
                                Text($0).textInputCompletion($0)
                            }
                        }
                    if fromSuggestion, let suggestion = s.suggestion {
                        Label {
                            Text(suggestion.how == .voice ? "Recognised from before"
                                 : "Guessed from the conversation\(suggestion.detail.isEmpty ? "" : " · “\(suggestion.detail.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")))”")")
                        } icon: {
                            Image(systemName: suggestion.how == .voice ? "person.crop.circle.badge.checkmark" : "quote.bubble")
                        }
                        .font(.callout)
                        .foregroundStyle(suggestion.how == .voice ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
            }
            if v.mixed || !absorbed.isEmpty {
                HStack(spacing: 4) {
                    Text(v.mixed ? "More than one person shares this voice, so their lines will be labelled “Several people”."
                         : "Includes \(absorbed.map { label(analysis, $0.id) }.joined(separator: ", ")).")
                    if !v.mixed && !absorbed.isEmpty {
                        Button("Undo") { for o in absorbed { voices[o.id]?.into = nil } }.buttonStyle(.link)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func clips(_ quotes: [Quote]) -> some View {
        HStack(spacing: 8) {
            ForEach(quotes, id: \.clip) { q in
                let on = player.playing == q.clip
                Button { player.toggle(q.clip) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 9))
                        Text(clock(q.start)).monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.opacity(0.18)).frame(width: on ? g.size.width * player.fraction : 0)
                        }
                    }
                    .background(Capsule().fill(Color.fill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(q.text)
            }
        }
    }

    private func transcript(_ analysis: Analysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    Text("Updates as you name voices").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(analysis.lines.enumerated()), id: \.offset) { _, l in
                    let name = nameOf(analysis, l.speaker)
                    let p = person(name, remember: false)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name).fontWeight(.semibold).foregroundStyle(p.isPerson ? p.color : .secondary)
                            Text(clock(l.start)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption)
                        Text(l.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func save(_ analysis: Analysis) {
        error = ""
        saving = true
        // An unnamed voice is sent with no name: it's saved as "Voice N" but never remembered as a person.
        let decisions = voices.mapValues { v -> Decision in
            if let into = v.into { return .merge(into: into) }
            return v.mixed ? .mixed : .name(v.name.trimmed)
        }
        Task {
            do {
                let folder = rec.folder ?? ""
                let saved = try await model.saveRecording(rec, decisions: decisions, folder: folder)
                let path = saved.path
                player.stop()
                model.refresh()
                model.folder = parentOf(path)
                // The tree reloads in the background; open the meeting once it's there.
                for _ in 0..<40 where model.tree?.find(path) == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                model.openMeeting(path)
                model.toast(saved.summaryError == nil ? "Saved to \(folderPath(folder))"
                            : "Saved to \(folderPath(folder)), without a summary for now")
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
