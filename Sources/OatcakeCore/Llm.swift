// Talking to the language model. It's always a model on this Mac (see LocalModel.swift) or on a
// server of your own on your network; both speak the same chat API. It only ever sees text.

import Foundation

/// What a local model's address gets when it isn't local (settings from a version that allowed any address).
public let notLocalMessage = "A model server of your own has to be on this Mac or your own network, and this address isn’t. Change it in Settings › Models, or choose one of Oatcake’s own models there."

/**
 * Whether a model server's address is on this Mac or your own network: localhost, a name with no
 * dots or ending in .local, or a private or link-local IP address. Oatcake sends transcripts to a
 * local model only at an address like that, so one can't be pointed at somebody else's service.
 */
public func isLocalEndpoint(_ address: String) -> Bool {
    guard let url = URL(string: address.trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
    if host.contains(":") {
        // IPv6: this Mac, link-local, or a unique local address.
        return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    // A part with a leading zero (010.8.8.8) is read as ten by some of the system and as eight by the
    // rest: whichever a request would use, it isn't how anyone writes an address they mean.
    if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), parts.contains(where: { $0.count > 1 && $0.first == "0" }) { return false }
    if parts.count == 4, let n = Optional(parts.compactMap { UInt8($0) }), n.count == 4 {
        return n[0] == 127 || n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168) || (n[0] == 169 && n[1] == 254)
    }
    // A bare number is an address written another way (134744072 is 8.8.8.8), not a machine's name.
    if UInt64(host) != nil || host.hasPrefix("0x") { return false }
    // A name: this Mac, a machine named on your network, or a Bonjour name.
    return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".")
}

/// Requests to a model's server don't follow redirects: one would send the transcript (and the key
/// to Oatcake's own server) to wherever it named, an address that was never checked to be local. A
/// redirect comes back as the server's answer, and so as an error.
let modelSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One turn of a conversation with the model.
public struct ChatMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }
}

/**
 * A chat server at a local address. Requests to Oatcake's own server follow Qwen's own advice for
 * its models: its sampling settings for each mode and never greedy decoding; a server of your own
 * keeps its own sampling. Every request leaves room for a long reply, and nothing of the model's
 * reasoning is kept in the conversation. Whether Oatcake's own model reasons before it replies is
 * the caller's to say: Settings › Summaries has a switch for each task (LlmConfig.Reasoning).
 */
public struct LocalChat: Sendable {
    public var baseUrl: String
    public var model: String
    /// The key Oatcake made up for its own server. None is sent to a server of yours.
    var key: String?
    /// Oatcake's own models: the sampling their makers recommend with reasoning on and off. They all
    /// take their reasoning switch from the chat template.
    var sampling: (thinking: Sampling, direct: Sampling)?
    /// A server of your own's reasoning switch, if you've said which it takes (Settings › Models).
    var reasoningControl: LlmConfig.ReasoningControl?

    public init(baseUrl: String, model: String) {
        self.baseUrl = baseUrl
        self.model = model
    }

    /// A server of your own, as Settings › Models has it.
    init(own: LlmConfig.Own) {
        self.init(baseUrl: own.baseUrl, model: own.model)
        reasoningControl = own.reasoningControl
    }

    init(baseUrl: String, model: String, key: String?, sampling: (thinking: Sampling, direct: Sampling)) {
        self.baseUrl = baseUrl
        self.model = model
        self.key = key
        self.sampling = sampling
    }

    private func request(_ path: String, timeout: TimeInterval) throws -> URLRequest {
        guard !baseUrl.trimmed.isEmpty, !model.trimmed.isEmpty else { throw OatcakeError("Set the endpoint and model in Settings first.") }
        guard isLocalEndpoint(baseUrl) else { throw OatcakeError(notLocalMessage) }
        guard let url = URL(string: baseUrl.trimmed.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression) + path) else {
            throw OatcakeError("The endpoint isn’t a valid address.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        return request
    }

    /// Whether Oatcake's own server has finished loading its model: llama.cpp's /health says so.
    func isReady() async -> Bool {
        let root = baseUrl.trimmed.replacingOccurrences(of: #"/v1/?$"#, with: "", options: .regularExpression)
        guard let url = URL(string: root + "/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await modelSession.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /**
     * The model's reply to a conversation. `schema` is a JSON Schema the reply must fit (the server
     * holds the model to it). `maxTokens` is room for the reasoning and the reply together.
     */
    public func complete(_ messages: [ChatMessage], schema: String? = nil, think: Bool = true, maxTokens: Int = 8_192) async throws -> String {
        var request = try request("/chat/completions", timeout: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            // The server keeps its reading of a prompt, so a second question about the same call starts at once.
            "cache_prompt": true,
        ]
        // The model's makers' sampling: thinking and non-thinking modes each have their own. A server
        // of your own keeps to its own sampling, which suits whatever model it runs. Oatcake's own
        // models take their reasoning switch from the chat template.
        if let sampling {
            let chosen = think ? sampling.thinking : sampling.direct
            body["temperature"] = chosen.temperature
            body["top_p"] = chosen.topP
            body["top_k"] = 20
            body["min_p"] = 0
            body["presence_penalty"] = chosen.presencePenalty
            body["chat_template_kwargs"] = ["enable_thinking": think]
        }
        // A server of your own is told only in the way you've said it understands. "medium" is a level
        // Ollama knows for every model that reasons; a model that only has on and off takes it as on.
        switch reasoningControl {
        case .ollama: body["reasoning_effort"] = think ? "medium" : "none"
        case .llamaCpp: body["chat_template_kwargs"] = ["enable_thinking": think]
        case nil: break
        }
        // The schema is sent exactly as it's written. The server makes the model fill in a reply's
        // fields in the schema's order, and that order matters: asked for a to-do's time before
        // its task, the model walks the call minute by minute and makes a to-do of each. Passed
        // through a dictionary, the fields came out in another order (the time first).
        let placeholder = "schema-\(UUID().uuidString)"
        let schemaAsWritten = schema.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil ? $0 : nil }
        if schemaAsWritten != nil {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "strict": true, "schema": placeholder]]
        }
        var sent = try JSONSerialization.data(withJSONObject: body)
        if let schemaAsWritten {
            sent = Data(String(decoding: sent, as: UTF8.self).replacingOccurrences(of: "\"\(placeholder)\"", with: schemaAsWritten).utf8)
        }
        request.httpBody = sent
        let data: Data, response: URLResponse
        do {
            (data, response) = try await modelSession.data(for: request)
        } catch let error as URLError where unreachableCodes.contains(error.code) {
            throw OatcakeError("The model at \(baseUrl) couldn’t be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let said = String(decoding: data, as: UTF8.self)
            // Ollama refuses to turn reasoning on for a model that can't reason ("… does not support
            // thinking", a 400 on its chat API). Asked again without the switch, that model just replies.
            if reasoningControl == .ollama, think, status == 400, said.contains("does not support thinking") {
                var plain = self
                plain.reasoningControl = nil
                return try await plain.complete(messages, schema: schema, think: think, maxTokens: maxTokens)
            }
            throw OatcakeError("The model at \(baseUrl) returned \(status): \(said.prefix(300))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (json?["choices"] as? [[String: Any]])?.first
        // Out of room, whatever it had written by then: its reasoning used it all, or the reply was cut
        // off part way (a summary that stops mid-sentence, to-dos with half their JSON).
        let reply = withoutReasoning(((choice?["message"] as? [String: Any])?["content"] as? String) ?? "")
        if choice?["finish_reason"] as? String == "length" { throw ModelOutOfRoom(reply: reply) }
        guard !reply.isEmpty else { throw OatcakeError("The model gave an empty reply.") }
        return reply
    }
}

/// What a small model writes where it was asked to leave a value empty.
let wordsForNothing: Set<String> = ["null", "none", "n/a", "unknown", "not stated", "not specified", "tbd"]

let outOfRoomMessage = "The model ran out of room before it finished its reply. Trying again usually works."

/// A reply cut off before it was finished, or before it began after the model's reasoning: the room it
/// was given ran out.
public struct ModelOutOfRoom: LocalizedError, Equatable {
    /// What it had written of its reply by then, without its reasoning.
    public var reply = ""
    public var errorDescription: String? { outOfRoomMessage }
}

/// A reply without the model's reasoning, for servers that leave it in the text between <think> tags.
/// Reasoning that's never closed is all there is: there's no reply after it.
func withoutReasoning(_ reply: String) -> String {
    reply.replacingOccurrences(of: #"(?s)^\s*<think>(.*?</think>|.*$)"#, with: "", options: .regularExpression).trimmed
}

/// What Check it works in Settings › Models found.
public enum ModelCheck: Equatable, Sendable {
    /// The model's reply.
    case replied(String)
    /// The model answered, but was still reasoning when the check's small allowance ran out.
    case stillReasoning
}

/**
 * Check it works in Settings › Models: one short request with these settings, asking for a one-word
 * reply. A server of your own decides for itself whether its model reasons first, and one that does
 * can spend the check's little room on that. It still answered, so the model is working.
 */
public func checkModel(_ llm: LlmConfig, server: ModelServer = .shared) async throws -> ModelCheck {
    do {
        // A one-word reply needs no reasoning. Loading the model is most of the wait.
        return .replied(try await withModel(llm, tokens: 100, server: server) { chat, _ in
            try await chat.complete([ChatMessage("system", "Reply with the single word OK and nothing else."), ChatMessage("user", "Say OK.")],
                                    think: false, maxTokens: 20)
        })
    } catch let cut as ModelOutOfRoom {
        // A reply that ran past the check's few tokens is a reply all the same.
        return cut.reply.isEmpty ? .stillReasoning : .replied(cut.reply)
    }
}

/**
 * Runs `work` with the model that's set in Settings, with room for a prompt of `tokens` tokens and
 * its reply. For one of Oatcake's own models this starts its server if it isn't running, with the
 * smallest window that fits (never more than this Mac has memory for), and keeps it as it is until
 * `work` is done. `work` is also told how many tokens the window holds. `server` is Oatcake's one
 * server, except in tests.
 */
public func withModel<T: Sendable>(_ config: LlmConfig, tokens: Int, server: ModelServer = .shared,
                                    _ work: (LocalChat, Int) async throws -> T) async throws -> T {
    guard let model = LocalModels.find(config.model) else {
        // A server of your own decides its window: the one you've told Oatcake, or else Qwen's native one.
        return try await work(LocalChat(own: config.own), config.own.contextBudget)
    }
    let context = min(LocalModels.context(forTokens: tokens), LocalModels.maxContext(model))
    let chat = try await server.lease(model, context: context)
    do {
        let result = try await work(chat, context)
        await server.release()
        return result
    } catch {
        await server.release()
        throw error
    }
}

/// The most tokens the chosen model can be given at once on this Mac.
public func largestContext(_ config: LlmConfig) -> Int {
    LocalModels.find(config.model).map { LocalModels.maxContext($0) } ?? config.own.contextBudget
}

/// The system's errors for a server that didn't answer at all. Told apart by these codes where the
/// request fails, not by the system's words, which are in the Mac's own language.
let unreachableCodes: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .timedOut]

/**
 * A model failure in plain words, with what to do about it. The raw message is shown behind
 * "Details" by the windows; an error that's already plain comes back unchanged. A request to the
 * model that failed is said in Oatcake's own words with the server's HTTP status (`complete`), and
 * is sorted by that status and the error code in the server's reply. Only a server that gives no
 * code for a call that's too long is read for its words.
 */
public func explainModelError(_ raw: String) -> String {
    if raw == notLocalMessage || raw == modelNotDownloadedMessage || raw == outOfRoomMessage { return raw }
    if raw.range(of: #"^The model at .+? couldn’t be reached: "#, options: .regularExpression) != nil {
        return "The model couldn’t be reached. If it’s a server of your own, check that it’s running."
    }
    guard let found = firstMatch(try! NSRegularExpression(pattern: #"^The model at .+? returned (\d{3}): (.*)"#, options: .dotMatchesLineSeparators), raw),
          let status = found[1].flatMap({ Int($0) }) else { return raw }
    let said = found[2] ?? "", words = said.lowercased()
    // llama.cpp's error type, or the code OpenAI's API (and the servers that copy it) gives; failing
    // those, the server's words.
    let tooLong = status == 413 || said.contains("exceed_context_size_error") || said.contains("context_length_exceeded")
        || words.contains("context") && ["exceed", "too long", "too large"].contains(where: words.contains)
    if tooLong { return "This call is too long for the model to take in at once on this Mac." }
    if status == 404 {
        let model = firstMatch(try! NSRegularExpression(pattern: #""model"\s*:\s*"([^"]+)""#), said)?[1]
        return "The model\(model.map { " “\($0)”" } ?? "") isn’t on that server. Check its name in Settings › Models."
    }
    return raw
}

/// Pulls the first JSON object out of a model reply (tolerates code fences and prose).
public func parseJsonObject<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw OatcakeError("No JSON in model reply: \(text.prefix(200))")
    }
    return try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
}
