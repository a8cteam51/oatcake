import OatcakeCore
import SwiftUI

extension SettingsView {
    /// Typed as one comma-separated line; kept as a list.
    @ViewBuilder var jargonSection: some View {
        Section {
            TextField("Jargon", text: $jargon, prompt: Text("Automattic, WooCommerce, Jetpack"), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
                .onChange(of: jargon) {
                    let terms = commaList(jargon)
                    if terms != model.config.jargon { model.saveConfig(with(model.config) { $0.jargon = terms }) }
                }
        } header: {
            Text("Jargon")
        } footer: {
            Text("Names, products and acronyms, separated by commas. Summaries, to-dos, name suggestions and answers spell them as written here. Transcripts keep what the speech model heard.")
                .settingsHint()
        }
    }

    /**
     * One section for each thing the model writes: its instructions (Oatcake's own until you change
     * them) beside its reasoning switch, so everything about one output is in one place.
     */
    @ViewBuilder var outputSections: some View {
        Section {
            InstructionsRow(title: "Summary instructions", setting: \.summaryInstructions, standard: defaultSummaryInstructions,
                            applies: "Used for summaries written from now on.")
            reasoningToggle(\.summary)
        } header: {
            Text("Summary")
        } footer: {
            Text("What the model writes once it has read the transcript. Change the headings, the level of detail or the language.").settingsHint()
        }
        TemplatesSections()
        if model.config.todosEnabled {
            Section {
                InstructionsRow(title: "To-do instructions", setting: \.todoInstructions, standard: defaultTodoInstructions,
                                applies: "Used for to-dos collected from now on.")
                reasoningToggle(\.todos)
            } header: {
                Text("To-dos")
            } footer: {
                Text("What counts as a to-do. Each still comes with its owner, due date and time in the call.").settingsHint()
            }
        }
        Section {
            InstructionsRow(title: "Draft for sharing instructions", setting: \.sharingInstructions, standard: defaultSharingInstructions,
                            applies: "Used for drafts written from now on.")
            reasoningToggle(\.sharing)
        } header: {
            Text("Draft for sharing")
        } footer: {
            Text("Draft for Sharing… in a meeting rewrites its \(model.config.todosEnabled ? "summary and to-dos" : "summary") for other people. It doesn’t read the transcript or your notes.").settingsHint()
        }
        Section {
            reasoningToggle(\.names, title: "Name suggestions")
            reasoningToggle(\.ask, title: "Ask")
        } header: {
            Text("Reasoning for name suggestions and Ask")
        }
    }

    /**
     * Whether the model thinks a task through before it replies. Oatcake's own models are always told,
     * and each comes with the switches that suited it; a server of yours only once you've said which
     * switch it takes (Settings › Models). Until then it decides for itself, so the switch is shown
     * but can't be changed.
     */
    private func reasoningToggle(_ task: WritableKeyPath<LlmConfig.Reasoning, Bool>, title: String = "Reasoning") -> some View {
        let undecided = LocalModels.find(model.config.llm.model) == nil && model.config.llm.own.reasoningControl == nil
        let reasoning: WritableKeyPath<LlmConfig, LlmConfig.Reasoning> = \.reasoning
        return Toggle(isOn: bindLlm(reasoning.appending(path: task))) {
            Text(title)
            Text(undecided ? "A model server of your own decides this for itself, until you choose its reasoning switch in Settings › Models."
                 : "The model thinks it through before replying, which is slower. Choosing one of Oatcake’s models in Settings › Models sets this to what suits it.")
        }
        .disabled(undecided)
    }
}

/**
 * One of the model's sets of instructions, as a row saying whose they are. Edit… opens them below it,
 * saved as they're typed; Restore default… brings Oatcake's own back.
 */
private struct InstructionsRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let setting: WritableKeyPath<Config, String>
    /// Oatcake's own wording.
    let standard: String
    let applies: String
    @ViewState private var text = ""
    @ViewState private var editing = false
    @ViewState private var restoring = false

    var body: some View {
        LabeledContent {
            HStack {
                // It only does anything when the instructions have been changed, and then it asks: they're yours.
                if editing {
                    Button("Restore default…") { restoring = true }.disabled(text.trimmed == standard.trimmed)
                        .alert("Restore Oatcake’s own \(title.lowercased())?", isPresented: $restoring) {
                            Button("Restore default", role: .destructive) { text = standard }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The instructions you’ve written here are replaced, and can’t be brought back.")
                        }
                }
                Button(editing ? "Done" : "Edit…") { editing.toggle() }
                    .accessibilityLabel(editing ? "Done editing \(title.lowercased())" : "Edit \(title.lowercased())")
            }
        } label: {
            Text(model.config[keyPath: setting].trimmed.isEmpty ? "Oatcake’s own instructions" : "Your instructions")
            Text(applies)
        }
        .onAppear {
            let custom = model.config[keyPath: setting].trimmed
            text = custom.isEmpty ? standard : custom
        }
        if editing {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(title)
                .onChange(of: text) {
                    // Oatcake's own wording is kept as "none of your own", so a later improvement to it reaches you.
                    let custom = text.trimmed == standard.trimmed ? "" : text
                    if custom != model.config[keyPath: setting] { model.saveConfig(with(model.config) { $0[keyPath: setting] = custom }) }
                }
        }
    }

    init(title: String, setting: WritableKeyPath<Config, String>, standard: String, applies: String) {
        self.title = title
        self.setting = setting
        self.standard = standard
        self.applies = applies
    }
}

/**
 * Summary templates: other summary instructions, each with a name, for the meetings that need a
 * different summary. One is picked for a meeting from its Regenerate menu, and kept for it.
 */
private struct TemplatesSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Button("Add template") { add() }
            } label: {
                Text(model.config.summaryTemplates.isEmpty ? "None yet" : model.config.summaryTemplates.map(\.name).joined(separator: ", "))
                Text("Pick one for a meeting from its ⋯ menu › Regenerate Summary.")
            }
        } header: {
            Text("Summary templates")
        } footer: {
            Text("Other summary instructions, each with a name: for a one-to-one you lead, say. A meeting keeps the template you regenerate it with; the rest use the summary instructions.")
                .settingsHint()
        }
        ForEach(model.config.summaryTemplates, id: \.name) { template in
            TemplateSection(template: template)
        }
    }

    /// A new one starts as a copy of the summary instructions, named "New template" (or "New template 2"…).
    private func add() {
        var name = "New template"
        var number = 2
        while model.config.summaryTemplates.contains(where: { $0.name.trimmed.lowercased() == name.lowercased() }) {
            name = "New template \(number)"
            number += 1
        }
        model.saveConfig(with(model.config) { $0.summaryTemplates.append(SummaryTemplate(name: name, instructions: $0.summaryTask)) })
    }
}

/// One summary template, to rename, edit or delete. Its instructions are saved as they're typed; its
/// name when you press Return or leave the field, or when the field goes (another pane, or Settings
/// closed), if no other template has it. Not as it's typed: the section is keyed by the name, so
/// saving each keystroke would remake the field under the cursor.
private struct TemplateSection: View {
    @Environment(AppModel.self) private var model
    /// As saved.
    let template: SummaryTemplate
    @ViewState private var name = ""
    @ViewState private var text = ""
    @ViewState private var nameProblem: String?
    @ViewState private var deleting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit(saveName)
                .onChange(of: nameFocused) { if !nameFocused { saveName() } }
                .onDisappear(perform: saveName)
            if let nameProblem {
                Text(nameProblem).settingsHint(.red)
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Instructions for \(template.name)")
                .onChange(of: text) { change { $0.instructions = text } }
            LabeledContent {
                Button("Delete…") { deleting = true }
                    .alert("Delete the “\(template.name)” template?", isPresented: $deleting) {
                        Button("Delete", role: .destructive) {
                            model.saveConfig(with(model.config) { $0.summaryTemplates.removeAll { $0.name == template.name } })
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Summaries already written with it stay as they are. Those meetings are summarised with the summary instructions from now on, or with a template you give this name again.")
                    }
            } label: {
                Text(text.trimmed.isEmpty ? "Without instructions, meetings use the summary instructions" : "Used for the meetings you regenerate with it")
            }
        } header: {
            Text(template.name)
        }
        .onAppear {
            name = template.name
            text = template.instructions
        }
    }

    private func change(_ edit: (inout SummaryTemplate) -> Void) {
        var config = model.config
        guard let i = config.summaryTemplates.firstIndex(where: { $0.name == template.name }) else { return }
        edit(&config.summaryTemplates[i])
        if config != model.config { model.saveConfig(config) }
    }

    private func saveName() {
        let clean = name.trimmed
        guard clean != template.name else {
            nameProblem = nil
            return
        }
        if clean.isEmpty {
            nameProblem = "A template needs a name."
        } else if model.config.summaryTemplates.contains(where: { $0.name != template.name && $0.name.trimmed.lowercased() == clean.lowercased() }) {
            nameProblem = "There’s a template called “\(clean)” already."
        } else {
            nameProblem = nil
            change { $0.name = clean }
            return
        }
        name = template.name
    }
}
