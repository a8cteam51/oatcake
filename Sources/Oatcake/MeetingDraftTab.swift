import OatcakeCore
import SwiftUI

extension MeetingView {
    /// The draft for sharing being written, or why it couldn't be. A draft already there stays meanwhile.
    @ViewBuilder var draftNotice: some View {
        if model.jobs.drafting.contains(path) {
            Notice(tone: .blue) {
                Text("Writing the draft for sharing…").fontWeight(.semibold)
                Text((files?[.draft] ?? "").trimmed.isEmpty ? "It’s written from the summary\(model.config.todosEnabled ? " and to-dos" : "")."
                     : "The draft that’s here stays until the new one is ready.")
            }.padding(.bottom, 16)
        } else if let error = model.jobs.draftErrors[path] {
            Notice(tone: .red) {
                ModelError(raw: error, prefix: "Couldn’t write the draft for sharing. ")
                if !(files?[.draft] ?? "").trimmed.isEmpty { Text("The draft that was here was kept.") }
                HStack(spacing: 10) {
                    Button("Try again") {
                        flush()
                        guard !model.edits.isWaiting(in: path) else { return }
                        model.jobs.draftForSharing(path, request: model.jobs.draftRequests[path] ?? "")
                    }
                    .disabled((files?[.summary] ?? "").trimmed.isEmpty || model.jobs.summarising.contains(path))
                    SettingsPaneLink(pane: .models, title: "Open Settings").buttonStyle(.link)
                    // Put aside: without a draft there's nothing else on this tab, so it goes too.
                    Button("Dismiss") {
                        model.jobs.draftErrors.removeValue(forKey: path)
                        model.jobs.draftRequests.removeValue(forKey: path)
                        if (files?[.draft] ?? "").trimmed.isEmpty { switchTab(.summary) }
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 6)
            }.padding(.bottom, 16)
        }
    }

    func draft(_ files: [FileKey: String]) -> some View {
        let text = files[.draft] ?? ""
        return Group {
            if !text.trimmed.isEmpty {
                SelectableMarkdown(markdown: text, fontSize: 14 * scale, marks: findWords, label: "Draft for sharing")
            } else if !model.jobs.drafting.contains(path) && model.jobs.draftErrors[path] == nil {
                Text("No draft for sharing in this meeting.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Draft for Sharing…: what the draft is written from, and anything wanted for this one alone. Its
/// button says whether it replaces a draft that's there, so it asks once.
struct DraftForSharingSheet: View {
    /// The meeting has a draft for sharing already, which the new one takes the place of.
    let replacing: Bool
    /// Whether to-dos are collected (Settings › General): while they're off, the sheet doesn't mention them.
    let todos: Bool
    let write: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Draft for sharing").font(.headline)
            Text("Oatcake’s model writes this meeting’s \(todos ? "summary and to-dos" : "summary") again for other people to read, following your draft for sharing instructions in Settings › Summaries. It doesn’t read the transcript or your notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("For this draft only (optional)")
                // Plain, with a border of its own: the rounded style draws one line whatever space is reserved.
                TextField("", text: $request, prompt: Text("Shorter, and leave out the budget"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                    .accessibilityLabel("For this draft only")
            }
            if replacing {
                Text("This replaces the draft for sharing that’s there, including your edits to it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replacing ? "Replace draft" : "Write draft") {
                    write(request.trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
