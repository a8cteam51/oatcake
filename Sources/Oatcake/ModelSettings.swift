import OatcakeCore
import SwiftUI

extension SettingsView {
    @ViewBuilder var transcription: some View {
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
            Text("Speech to text")
        } footer: {
            Text("Runs on your Mac. Audio never leaves it for transcription.").settingsHint()
        }
    }

    @ViewBuilder var llmSection: some View {
        let llm = model.config.llm
        Section {
            Picker("Language model", selection: Binding(get: { llm.model }, set: choose)) {
                ForEach(LocalModels.all) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title + (choice == LocalModels.recommended() ? " · recommended for this Mac" : choice.legacy ? " · older model" : ""))
                        Text(choice.detail).settingsHint()
                        if !LocalModels.fits(choice) {
                            Text("This Mac has \(Int(LocalModels.physicalMemory.rounded())) GB of memory, which is too little for it.").settingsHint(.amber)
                        }
                        // Beside the choice that was just made, where it's seen.
                        if choice.id == llm.model, let reasoningNote {
                            Text("\(Image(systemName: "info.circle")) \(reasoningNote)").settingsHint(.primary)
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
        } header: {
            Text("Language model")
        } footer: {
            Text("Writes summaries, to-dos and drafts for sharing, suggests names and answers questions. It runs on this Mac; nothing from your calls is sent anywhere.")
                .settingsHint()
        }
        // The chosen model's download (or the server's details) and Test, in a group under the list:
        // in the same group as the models, its status read as one more model to choose.
        Section {
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
                // How much Oatcake sends at once. The server keeps its own setting: this only has to match it.
                TextField(value: bindLlm(\.own.context), format: .number.grouping(.never),
                          prompt: Text(String(LocalModels.nativeContext))) {
                    Text("Context").font(.body)
                    if let context = llm.own.context, context < LlmConfig.Own.minimumContext {
                        Text("Too small: Oatcake needs at least \(LlmConfig.Own.minimumContext.formatted()) and will assume that")
                            .font(.callout).foregroundStyle(Color.amber)
                    } else {
                        Text("Tokens your server is set to hold (Ollama’s num_ctx, llama.cpp’s -c). This tells Oatcake how much to send at once; it doesn’t change the server. Empty: \(LocalModels.nativeContext.formatted()).")
                            .settingsHint()
                    }
                }
                .font(.system(.body, design: .monospaced))
                Picker(selection: bindLlm(\.own.reasoningControl)) {
                    Text("Leave it to the server").tag(nil as LlmConfig.ReasoningControl?)
                    Text("Ollama (reasoning_effort)").tag(Optional(LlmConfig.ReasoningControl.ollama))
                    Text("llama.cpp (enable_thinking)").tag(Optional(LlmConfig.ReasoningControl.llamaCpp))
                } label: {
                    Text("Reasoning switch")
                    Text(llm.own.reasoningControl == nil
                         ? "The server decides whether its model reasons first. Choose the switch it takes to use the Reasoning switches in Settings › Summaries."
                         : "Each task’s Reasoning switch in Settings › Summaries is sent this way. A model that can’t turn reasoning off uses its lowest setting.")
                        .settingsHint()
                }
            }
            TestRow(missing: testBlocker(llm)).id(llm.model)
        }
    }

    /**
     * One of Oatcake's models comes with the reasoning switches that suited it in Oatcake's tests,
     * which replace the ones set before: Settings says which changed. A server of your own keeps
     * the switches as they are.
     */
    private func choose(_ id: String) {
        let before = model.config.llm
        guard id != before.model else { return }
        let chosen = LocalModels.find(id)
        model.saveConfig(with(model.config) {
            $0.llm.model = id
            if let chosen { $0.llm.reasoning = chosen.reasoning }
        })
        reasoningNote = chosen.flatMap { chosen in
            before.reasoning.change(to: chosen.reasoning).map {
                "Reasoning is now \($0), which suits \(chosen.title) best. You can change it in Settings › Summaries."
            }
        }
        if let reasoningNote { announce(reasoningNote) }
    }

    /// Why Test can't be pressed yet, if it can't.
    private func testBlocker(_ llm: LlmConfig) -> String? {
        let _ = model.downloads.modelsVersion
        if let chosen = LocalModels.find(llm.model) { return LocalModels.isDownloaded(chosen) ? nil : "Download the model first." }
        if llm.own.baseUrl.trimmed.isEmpty || llm.own.model.trimmed.isEmpty { return "Fill in the endpoint and model first." }
        return isLocalEndpoint(llm.own.baseUrl) ? nil : "The endpoint has to be on this Mac or your own network."
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
            let check = try await withThrowingTaskGroup(of: ModelCheck.self) { group in
                group.addTask { try await checkModel(llm) }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw OatcakeError("No reply after two minutes")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let time = String(format: "%.1f", Date().timeIntervalSince(started))
            switch check {
            case .replied(let reply):
                result = (true, "Working: replied “\(reply.trimmed.prefix(40))” in \(time) s.")
            case .stillReasoning:
                result = (true, "Working: the model answered in \(time) s, but was still reasoning when this check stopped it. Summaries and other tasks give it far more room.")
            }
        } catch {
            result = (false, String(explainModelError(error.localizedDescription).prefix(300)))
        }
        running = false
    }
}

/// Settings › Models: whether the chosen model is on this Mac, with its download or removal.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let chosen: LocalModel
    @ViewState private var removing = false

    var body: some View {
        let _ = model.downloads.modelsVersion
        if let fraction = model.downloads.modelDownloads[chosen.id] {
            LabeledContent {
                Button("Stop") { model.downloads.stopModelDownload(chosen) }
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
                Button("Remove", role: .destructive) { model.downloads.removeModel(chosen) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(chosen.downloadSize). It’s downloaded again the next time it’s needed.")
            }
        } else {
            let error = model.downloads.modelDownloadErrors[chosen.id]
            LabeledContent {
                HStack {
                    // A download that was stopped, or failed, leaves what it had fetched: gigabytes that only this removes.
                    if LocalModels.hasPartialDownload(chosen) {
                        Button("Remove partial download…") { removing = true }
                            .help("Deletes the part of \(chosen.title) that has been downloaded so far")
                            .alert("Remove the part of \(chosen.title) downloaded so far?", isPresented: $removing) {
                                Button("Remove", role: .destructive) { model.downloads.removeModel(chosen) }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Its download starts again from the beginning the next time it’s needed.")
                            }
                    }
                    Button(error == nil ? "Download now" : "Try again") { model.downloads.downloadModel(chosen) }
                }
            } label: {
                Text("\(chosen.title) isn’t downloaded yet")
                Text(error ?? "\(chosen.downloadSize), from Hugging Face. It downloads by itself during your first call, or when it’s first needed.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
        }
    }
}
