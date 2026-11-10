import Foundation

public struct AskAnswer: Sendable {
    public var answer: String
    /// Pass back to continue the same conversation.
    public var sessionId: String
}

private func askSystemPrompt(_ myName: String) -> String {
    [
        "You answer \(myName)'s questions about their meetings. The current directory holds one folder per meeting",
        "(grouped into series folders), each with summary.md, transcript.md (lines like '**[mm:ss] Name:** text'),",
        "notes.md (\(myName)'s own notes, when any were taken) and meeting.json. Folder names start with the date: 'YYYY-MM-DD HHMM Title'.",
        "Start with the meeting they're looking at. Search other meetings (Grep across */*/summary.md first, then",
        "transcripts) whenever the question reaches beyond it, such as earlier discussions, people or recurring topics.",
        "Answer in concise Markdown. Cite each meeting you draw on as a Markdown link whose target is the meeting",
        "folder's path relative to the current directory, URL-encoded (spaces as %20, & as %26), with the meeting's title",
        "and short date as the link text, e.g. [Leads sync · Oct 29](...). Add transcript timestamps like [12:34] where",
        "they help. If the meetings don't answer the question, say so.",
    ].joined(separator: " ")
}

/// Describes a tool call in a few words, for the progress line.
private func describeTool(root: URL, name: String, input: [String: Any]) -> String? {
    switch name {
    case "Read":
        guard let path = input["file_path"] as? String else { return "Reading" }
        return "Reading " + relativePath(URL(fileURLWithPath: path), to: root).replacingOccurrences(of: "/", with: " › ")
    case "Grep": return "Searching for “\(input["pattern"] as? String ?? "")”"
    case "Glob": return "Listing meetings"
    default: return nil
    }
}

/// A question to Claude Code that can be stopped while it runs.
public final class AskRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }

    fileprivate func started(_ p: Process) {
        lock.withLock {
            process = p
            if cancelled { p.terminate() }
        }
    }

    fileprivate var wasCancelled: Bool { lock.withLock { cancelled } }

    /**
     * Asks Claude Code a question about the meetings. It runs in the meetings folder with read-only
     * file tools (Read, Grep, Glob) allowed only inside that folder: no shell, no MCP servers, no user
     * settings or CLAUDE.md. A transcript that tries to steer it (anything said on a call ends up in one)
     * can't reach files elsewhere on the Mac.
     */
    public func run(root: URL, meeting: String, question: String, sessionId: String?, myName: String, model: String?,
                    onStep: @escaping @Sendable (String) -> Void) async throws -> AskAnswer {
        if let sessionId, sessionId.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            throw OatcakeError("That conversation can't be continued. Start a new chat.")
        }
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--system-prompt", askSystemPrompt(myName),
                    "--tools", "Read,Grep,Glob", "--allowedTools", "Read(./**),Grep(./**),Glob(./**)",
                    "--strict-mcp-config", "--setting-sources", ""]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let sessionId { args += ["--resume", sessionId] }
        // Said every time: the conversation carries on as they move between meetings.
        let prompt = "I'm looking at the meeting in \"\(meeting)\".\n\n\(question)"

        final class Final: @unchecked Sendable { var event: [String: Any]? }
        let final = Final()
        let result = try await ChildProcess.run(try claudeExecutable(), args, input: prompt, directory: root, onStart: started) { line in
            guard let data = line.data(using: .utf8), let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if event["type"] as? String == "assistant", let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_use" {
                    if let step = describeTool(root: root, name: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:]) {
                        onStep(step)
                    }
                }
            }
            if event["type"] as? String == "result" { final.event = event }
        }
        if wasCancelled { throw OatcakeError("Stopped.") }
        if let event = final.event, event["is_error"] as? Bool != true, let session = event["session_id"] as? String {
            return AskAnswer(answer: (event["result"] as? String ?? "").trimmed, sessionId: session)
        }
        let message = final.event?["result"] as? String
        throw OatcakeError(message ?? (result.stderr.trimmed.isEmpty ? "claude exited \(result.status)" : result.stderr.trimmed))
    }
}
