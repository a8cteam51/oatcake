// The model that writes summaries and suggests names: Claude Code, the Anthropic API, or any
// OpenAI-compatible server. Claude is the only language model Oatcake uses; it only sees text.

import Foundation

/// Anything that can answer one prompt. To add a model, add a provider and a case in makeLlm.
public protocol Llm: Sendable {
    var label: String { get }
    func complete(system: String, prompt: String) async throws -> String
}

public func makeLlm(_ config: LlmConfig) -> Llm {
    switch config.provider {
    case .claudeCode: ClaudeCodeLlm(model: config.claudeCode.model, effort: config.claudeCode.effort)
    case .anthropic: AnthropicLlm(model: config.anthropic.model, effort: config.anthropic.effort, key: Secrets.get(.anthropic))
    case .openaiCompatible: OpenAICompatibleLlm(baseUrl: config.openai.baseUrl, model: config.openai.model, effort: config.openai.effort, key: Secrets.get(.openai))
    }
}

/// Pulls the first JSON object out of a model reply (tolerates code fences and prose).
public func parseJsonObject<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw OatcakeError("No JSON in model reply: \(text.prefix(200))")
    }
    return try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
}

/**
 * Runs `claude -p`, reusing the user's Claude Code login. No tools, no MCP, no saved session, and no
 * user or project settings, so personal CLAUDE.md rules don't leak into replies.
 */
struct ClaudeCodeLlm: Llm {
    let model: String
    let effort: Effort
    var label: String { "Claude Code\(model.isEmpty ? "" : " (\(model))")" }

    func complete(system: String, prompt: String) async throws -> String {
        var args = ["-p", "--output-format", "text", "--system-prompt", system, "--tools", "",
                    "--strict-mcp-config", "--no-session-persistence", "--setting-sources", ""]
        if !model.isEmpty { args += ["--model", model] }
        args += ["--effort", effort.rawValue]
        let result = try await ChildProcess.run(try claudeExecutable(), args, input: prompt, directory: FileManager.default.temporaryDirectory)
        guard result.status == 0 else {
            throw OatcakeError("claude exited \(result.status): \(result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed)")
        }
        return result.stdout.trimmed
    }
}

func claudeExecutable() throws -> URL {
    guard let url = ShellEnvironment.which("claude") else {
        throw OatcakeError("This needs Claude Code installed and signed in (the claude command).")
    }
    return url
}

/**
 * Claude through the Anthropic API, streamed. Server-side refusal fallbacks are on, so a declined
 * request is retried on a fallback model inside the same call.
 */
struct AnthropicLlm: Llm {
    let model: String
    let effort: Effort
    let key: String
    var label: String { "\(model) via Anthropic API" }

    func complete(system: String, prompt: String) async throws -> String {
        guard !key.isEmpty else { throw OatcakeError("Add an Anthropic API key in Settings first.") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": effort.rawValue],
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw OatcakeError("The Anthropic API returned \(status): \(apiErrorMessage(body))")
        }
        var text = ""
        var stopReason: String?
        var explanation: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String {
                    text += piece
                }
            case "message_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any], let text = details["explanation"] as? String { explanation = text }
            case "error":
                let error = event["error"] as? [String: Any] ?? [:]
                throw OatcakeError("The Anthropic API stopped: \(error["message"] as? String ?? "unknown error")")
            default:
                break
            }
        }
        if stopReason == "refusal" { throw OatcakeError("Claude declined: \(explanation ?? "no explanation")") }
        return text.trimmed
    }
}

private func apiErrorMessage(_ body: String) -> String {
    if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let message = (json["error"] as? [String: Any])?["message"] as? String {
        return message
    }
    return String(body.prefix(300))
}

/// Any OpenAI-style chat completions endpoint: OpenAI, OpenRouter, or a local Ollama / LM Studio.
struct OpenAICompatibleLlm: Llm {
    let baseUrl: String
    let model: String
    let effort: Effort
    let key: String
    var label: String { "\(model) via \(baseUrl)" }

    func complete(system: String, prompt: String) async throws -> String {
        guard !baseUrl.trimmed.isEmpty, !model.trimmed.isEmpty else { throw OatcakeError("Set the endpoint and model in Settings first.") }
        guard let url = URL(string: baseUrl.trimmed.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression) + "/chat/completions") else {
            throw OatcakeError("The endpoint isn't a valid address.")
        }
        func send(withEffort: Bool) async throws -> (Data, Int) {
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            ]
            if withEffort { body["reasoning_effort"] = effort.rawValue }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Servers and models without reasoning reject the effort setting; ask again without it.
        var (data, status) = try await send(withEffort: true)
        if status == 400 { (data, status) = try await send(withEffort: false) }
        guard (200..<300).contains(status) else {
            throw OatcakeError("\(baseUrl) returned \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        return ((choices?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
    }
}

/// A child process with its input written and its output collected, without blocking a thread.
public enum ChildProcess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ executable: URL, _ arguments: [String], input: String? = nil, directory: URL? = nil,
                           onStart: ((Process) -> Void)? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ShellEnvironment.childEnvironment()
        if let directory {
            process.currentDirectoryURL = directory
            // Claude Code takes its working folder (which Ask's file tools are confined to) from PWD,
            // not only from the process's actual directory.
            environment["PWD"] = directory.path
        }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collected = Collected()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collected.appendOut(data, onLine: onLine)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.appendErr(data) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Whatever arrived after the last readability callback.
                collected.appendOut(stdout.fileHandleForReading.readDataToEndOfFile(), onLine: onLine)
                collected.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
                collected.flush(onLine: onLine)
                continuation.resume(returning: Result(status: p.terminationReason == .uncaughtSignal ? -p.terminationStatus : p.terminationStatus,
                                                      stdout: collected.out, stderr: collected.err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            onStart?(process)
            // On another thread: a long prompt can fill the pipe before the child starts reading.
            DispatchQueue.global().async {
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private var pending = Data()
        var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }

        func appendOut(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
            guard !data.isEmpty else { return }
            var lines: [String] = []
            lock.withLock {
                outData.append(data)
                guard onLine != nil else { return }
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending = Data(pending[pending.index(after: newline)...])
                }
            }
            lines.forEach { onLine?($0) }
        }

        func appendErr(_ data: Data) { lock.withLock { errData.append(data) } }

        func flush(onLine: (@Sendable (String) -> Void)?) {
            let rest = lock.withLock { () -> String in
                defer { pending = Data() }
                return String(decoding: pending, as: UTF8.self)
            }
            if !rest.isEmpty { onLine?(rest) }
        }
    }
}
