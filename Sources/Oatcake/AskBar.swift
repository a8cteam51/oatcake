import OatcakeCore
import SwiftUI

private let suggestions = [
    "What did we decide in this call?",
    "What’s still open from earlier meetings like this one?",
    "Who said they’d follow up, and on what?",
]

/// The floating "ask about your meetings" lozenge; the conversation opens above it.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    let path: String
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let chat = model.ask
        VStack(spacing: 10) {
            if chat.open { panel(chat) }
            HStack(spacing: 8) {
                TextField(chat.turns.isEmpty ? "Ask about this call, or any other…" : "Ask a follow-up…", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { submit() }
                if chat.running != nil {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(RoundButtonStyle(filled: true)).help("Stop")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(RoundButtonStyle(filled: !draft.trimmed.isEmpty)).help("Send (Return)")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .onChange(of: focused) { if focused, !chat.turns.isEmpty { chat.open = true } }
        .onKeyPress(.escape) {
            guard chat.open else { return .ignored }
            chat.open = false
            focused = false
            return .handled
        }
    }

    private func submit(_ text: String? = nil) {
        let question = (text ?? draft).trimmed
        guard !question.isEmpty, model.ask.running == nil else { return }
        draft = ""
        model.ask.send(question, meeting: path, config: model.config)
    }

    private func panel(_ chat: AskChat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask about your meetings").font(.headline)
                Spacer()
                Button("New chat") { chat.newChat(); focused = true }.disabled(chat.running != nil)
                Button("Hide") { chat.open = false }.help("Hide (Esc)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.turns) { turn in turnView(turn).id(turn.id) }
                        if chat.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask anything across your meetings. Answers link to the meetings they draw on.").foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { q in
                                    Button(q) { submit(q) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Show the newest question at the top, so a long answer is read from its start.
                .onChange(of: chat.turns.count) { if let last = chat.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } } }
            }
            .frame(maxHeight: 420)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
        .frame(maxWidth: 640)
        .environment(\.openURL, OpenURLAction { url in
            if let rel = meetingPath(from: url) {
                model.openMeeting(rel)
                return .handled
            }
            return .discarded
        })
    }

    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).fontWeight(.semibold)
            if let answer = turn.answer {
                MarkdownView(markdown: answerMarkdown(answer), fontSize: 13)
            } else if let error = turn.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if turn.stopped {
                Text("Stopped.").foregroundStyle(.secondary)
            } else {
                // The elapsed-time counter while an answer is on its way.
                TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(turn.step ?? "Thinking")…").lineLimit(1)
                        Text("\(Int(context.date.timeIntervalSince(turn.startedAt))) s").foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RoundButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 28)
            .background(Circle().fill(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.fill)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
