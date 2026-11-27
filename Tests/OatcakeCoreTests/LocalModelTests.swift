import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct LocalModelTests {
    @Test func localModelsOnly() async throws {
        // This Mac, a machine on your network, or a private address.
        for address in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", "http://mac-studio:11434/v1", "http://ollama/v1",
                        "http://studio.local:11434/v1", "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "https://172.20.1.1/v1"] {
            #expect(isLocalEndpoint(address), "\(address)")
        }
        // Anyone else's service, or not an address at all.
        for address in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1",
                        "https://localhost.example.com/v1", "ftp://localhost/v1", "localhost:11434", "",
                        // A public address written as one number isn't a machine's name.
                        "http://134744072/v1", "http://0x08080808/v1",
                        // Nor one with a leading zero, which is read two ways.
                        "http://010.8.8.8/v1", "http://0177.0.0.1/v1"] {
            #expect(!isLocalEndpoint(address), "\(address)")
        }
        // A server of your own pointed somewhere else is refused before anything is sent.
        var config = LlmConfig(model: LlmConfig.ownServer)
        config.own.baseUrl = "https://api.openai.com/v1"
        config.own.model = "gpt"
        await #expect(throws: OatcakeError(notLocalMessage)) {
            _ = try await withModel(config, tokens: 100) { chat, _ in try await chat.complete([ChatMessage("user", "Hello")]) }
        }
        // No key is kept for a model any more.
        #expect(SecretName.allCases.map(\.rawValue) == ["calendar"])
    }

    /// Which model a Mac starts with, and how much it's given to read at once, go by its memory.
    @Test func modelsByMemory() throws {
        // The list is best first: the recommendation is the first that fits and isn't an older model
        // kept for those who chose it, and nothing before it in the list would have fitted.
        for memory in [8.0, 16, 18, 24, 32, 36, 48, 64, 128] {
            let pick = LocalModels.recommended(memory: memory)
            #expect(!pick.legacy && LocalModels.fits(pick, memory: memory), "\(memory) GB")
            #expect(!LocalModels.all.prefix { $0 != pick }.contains { !$0.legacy && LocalModels.fits($0, memory: memory) }, "\(memory) GB")
        }
        // Qwen3.6 35B-A3B where it fits, from 32 GB; Qwen3.5 4B below that. Gemma 4 is there to choose
        // instead, never to start with. Qwen3 is kept for those who chose it.
        let large = try #require(LocalModels.find("qwen3.6-35b-a3b")), small = try #require(LocalModels.find("qwen3.5-4b"))
        for memory in [8.0, 16, 18, 24] { #expect(LocalModels.recommended(memory: memory) == small, "\(memory) GB") }
        for memory in [32.0, 36, 48, 64, 128] { #expect(LocalModels.recommended(memory: memory) == large, "\(memory) GB") }
        #expect(LocalModels.all.filter(\.legacy).map(\.id) == ["qwen3-8b", "qwen3-4b"])
        let gemma = try #require(LocalModels.find("gemma-4-26b-a4b")), smallGemma = try #require(LocalModels.find("gemma-4-12b"))
        #expect(!gemma.legacy && !smallGemma.legacy)
        #expect(!LocalModels.fits(gemma, memory: 18) && LocalModels.fits(gemma, memory: 24))
        #expect(!LocalModels.fits(smallGemma, memory: 8) && LocalModels.fits(smallGemma, memory: 16))
        // Each starts with the reasoning that suited it: Qwen3 as before, the newer ones with none,
        // as they reason for minutes before a summary that's no better for it.
        #expect(LocalModels.all.allSatisfy { $0.reasoning == ($0.legacy ? LlmConfig.Reasoning() : LlmConfig.Reasoning(summary: false, todos: false, names: false, ask: false, sharing: false)) })
        let qwen3 = try #require(LocalModels.find("qwen3-8b"))
        #expect(!LocalModels.fits(qwen3, memory: 8) && LocalModels.fits(qwen3, memory: 16))
        #expect(LocalModels.maxContext(qwen3, memory: 16) == 32_768 && LocalModels.maxContext(qwen3, memory: 36) == 131_072)
        // The smallest window that holds the job, so no more memory is taken than it needs.
        #expect(LocalModels.context(forTokens: 3_000) == 8_192 && LocalModels.context(forTokens: 20_000) == 24_576)
        #expect(LocalModels.context(forTokens: 500_000) == 131_072)
        // A window stretched past the model's own is for a text that needs it: a job that fits never
        // borrows a server that's running stretched, and a bigger window of the same kind is shared.
        #expect(qwen3.stretch(32_768) == 1 && qwen3.stretch(49_152) == 2 && qwen3.stretch(131_072) == 4)
        #expect(qwen3.serves(running: 32_768, needed: 8_192) && qwen3.serves(running: 65_536, needed: 49_152))
        #expect(!qwen3.serves(running: 49_152, needed: 32_768) && !qwen3.serves(running: 16_384, needed: 32_768))
        // A model trained on a longer text is never stretched for one Oatcake would send it.
        for model in LocalModels.all where model.nativeContext >= 131_072 {
            #expect(model.stretch(131_072) == 1 && model.serves(running: 131_072, needed: 8_192))
        }
        // The files are the ones that were measured: a fixed revision, with its size and checksum, from
        // Qwen, from llama.cpp's own conversions of Qwen's models, or from Google; each with a name of its own.
        for model in LocalModels.all {
            #expect(["Qwen", "ggml-org", "google"].contains { model.url.hasPrefix("https://huggingface.co/\($0)/") })
            #expect(model.url.range(of: #"/resolve/[0-9a-f]{40}/"#, options: .regularExpression) != nil && model.url.hasSuffix("/" + model.file))
            #expect(model.sha256.count == 64 && model.bytes > 2_000_000_000)
        }
        #expect(Set(LocalModels.all.map(\.file)).count == LocalModels.all.count && Set(LocalModels.all.map(\.id)).count == LocalModels.all.count)
        // A model that reasons at length gets room for it; a server of your own gets what Qwen3 does.
        for model in LocalModels.all { #expect(replyRoom(LlmConfig(model: model.id)) == model.replyTokens && model.replyTokens >= replyTokens) }
        #expect(replyRoom(LlmConfig(model: LlmConfig.ownServer)) == replyTokens)
    }

    /// What goes to the model's server: its makers' sampling for each mode, its reasoning switch, the
    /// shape a reply must fit, and the key Oatcake made up for its own server.
    @Test func requests() async throws {
        let server = try await StandIn.model { _ in "<think>\nLet me see.\n</think>\n\nOK" }
        let qwen3 = try #require(LocalModels.find("qwen3-8b"))
        let own = LocalChat(baseUrl: server.address + "/v1", model: "qwen3-8b", key: "made-up", sampling: (qwen3.thinking, qwen3.direct))
        #expect(await own.isReady() && server.requests.last?.path == "/health")
        #expect(try await own.complete([ChatMessage("system", "Be brief."), ChatMessage("user", "Say OK.")], schema: todosSchema) == "OK")
        #expect(try await own.complete([ChatMessage("user", "Say OK.")], think: false, maxTokens: 20) == "OK")
        let sent = server.requests.filter { $0.path == "/v1/chat/completions" }
        #expect(sent.count == 2 && sent.allSatisfy { $0.headers["authorization"] == "Bearer made-up" })
        let thinking = sent[0].json, plain = sent[1].json
        #expect(thinking["temperature"] as? Double == 0.6 && thinking["top_p"] as? Double == 0.95 && thinking["top_k"] as? Int == 20)
        #expect(thinking["presence_penalty"] as? Double == 1.5 && thinking["min_p"] as? Int == 0 && thinking["cache_prompt"] as? Bool == true)
        #expect((thinking["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect(((thinking["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] != nil)
        // The schema arrives as it's written, its fields in their order: the model fills them in that order.
        #expect(String(decoding: sent[0].body, as: UTF8.self).contains("\"schema\":" + todosSchema))
        #expect(thinking["max_tokens"] as? Int == 8_192 && sent[0].messages.system == "Be brief.")
        #expect(plain["temperature"] as? Double == 0.7 && plain["top_p"] as? Double == 0.8 && plain["max_tokens"] as? Int == 20)
        #expect((plain["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false && plain["response_format"] == nil)
        // Qwen3.5 and Qwen3.6 run hotter with reasoning on, and the same as Qwen3 with it off.
        let newer = try #require(LocalModels.find("qwen3.6-35b-a3b"))
        let next = LocalChat(baseUrl: server.address + "/v1", model: newer.id, key: "made-up", sampling: (newer.thinking, newer.direct))
        _ = try await next.complete([ChatMessage("user", "Say OK.")], think: true)
        _ = try await next.complete([ChatMessage("user", "Say OK.")], think: false)
        let (hot, cool) = (server.requests[server.requests.count - 2].json, server.requests[server.requests.count - 1].json)
        #expect(hot["temperature"] as? Double == 1.0 && hot["top_p"] as? Double == 0.95 && hot["presence_penalty"] as? Double == 1.5)
        #expect(cool["temperature"] as? Double == 0.7 && cool["top_p"] as? Double == 0.8 && cool["presence_penalty"] as? Double == 1.5)
        // Gemma 4 samples the same either way, from more of the likeliest tokens and with no penalty.
        let gemma = try #require(LocalModels.find("gemma-4-26b-a4b"))
        let google = LocalChat(baseUrl: server.address + "/v1", model: gemma.id, key: "made-up", sampling: (gemma.thinking, gemma.direct))
        _ = try await google.complete([ChatMessage("user", "Say OK.")], think: true)
        _ = try await google.complete([ChatMessage("user", "Say OK.")], think: false)
        for sent in server.requests.suffix(2).map(\.json) {
            #expect(sent["temperature"] as? Double == 1.0 && sent["top_p"] as? Double == 0.95 && sent["top_k"] as? Int == 64)
            #expect(sent["presence_penalty"] as? Double == 0 && sent["min_p"] as? Int == 0)
        }
        #expect(server.requests.suffix(2).map { ($0.json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool } == [true, false])

        // A server of your own gets no key, no switch it may not know, and none of Qwen's sampling:
        // it keeps its own. The room for the reply and the shape it must fit still go.
        let yours = try await withModel(server.config.llm, tokens: 100) { chat, context in
            #expect(context == LocalModels.nativeContext)
            return try await chat.complete([ChatMessage("user", "Say OK.")])
        }
        #expect(yours == "OK" && server.requests.last?.headers["authorization"] == nil && server.requests.last?.json["chat_template_kwargs"] == nil)
        let mine = LocalChat(baseUrl: server.address + "/v1", model: "stand-in")
        _ = try await mine.complete([ChatMessage("user", "Say OK.")], schema: todosSchema, think: true)
        _ = try await mine.complete([ChatMessage("user", "Say OK.")], think: false, maxTokens: 20)
        let ownSent = server.requests.suffix(2)
        #expect(ownSent.allSatisfy { $0.leavesSampling } && ownSent.first?.json["max_tokens"] as? Int == 8_192 && ownSent.last?.json["max_tokens"] as? Int == 20)
        #expect(String(decoding: ownSent.first!.body, as: UTF8.self).contains("\"schema\":" + todosSchema) && ownSent.last?.json["response_format"] == nil)

        // A reply that's all reasoning, cut off before the answer, is an error rather than an empty summary.
        let cut = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8))
        }
        await #expect(throws: ModelOutOfRoom()) {
            _ = try await LocalChat(baseUrl: cut.address + "/v1", model: "m").complete([ChatMessage("user", "Hello")])
        }
    }

    /// A reply cut off part way is out of room too, not a finished one: a summary that stops
    /// mid-sentence isn't saved as if it were whole. Reasoning left in the reply and never closed is
    /// all there was, so there's no reply.
    @Test func cutOffReplies() async throws {
        let partWay = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":"Decisions:\n\n- Jane will send the"},"finish_reason":"length"}]}"#.utf8))
        }
        await #expect(throws: ModelOutOfRoom(reply: "Decisions:\n\n- Jane will send the")) {
            _ = try await LocalChat(baseUrl: partWay.address + "/v1", model: "m").complete([ChatMessage("user", "Hello")])
        }
        let unclosed = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":"<think>\nThe user wants a summary. First"},"finish_reason":"length"}]}"#.utf8))
        }
        await #expect(throws: ModelOutOfRoom()) {
            _ = try await LocalChat(baseUrl: unclosed.address + "/v1", model: "m").complete([ChatMessage("user", "Hello")])
        }

        #expect(withoutReasoning("<think>\nThe user wants a summary.\nFirst, the") == "")
        #expect(withoutReasoning("<think>\nLet me see.\n</think>\n\nOK") == "OK")
        #expect(withoutReasoning("OK, and <think> isn’t reasoning here") == "OK, and <think> isn’t reasoning here")
    }

    /// A server of your own is told whether to reason only in the way you've said it takes: Ollama's
    /// reasoning_effort, or llama.cpp's enable_thinking. Left to the server, neither is sent.
    @Test func ownServerReasoningControl() async throws {
        let server = try await StandIn.model { _ in "OK" }
        func sent(_ control: LlmConfig.ReasoningControl?, think: Bool) async throws -> [String: Any] {
            var own = server.config.llm.own
            own.reasoningControl = control
            _ = try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: think)
            return try #require(server.requests.last).json
        }
        let ollamaOn = try await sent(.ollama, think: true), ollamaOff = try await sent(.ollama, think: false)
        #expect(ollamaOn["reasoning_effort"] as? String == "medium" && ollamaOff["reasoning_effort"] as? String == "none")
        #expect(ollamaOn["chat_template_kwargs"] == nil && ollamaOff["chat_template_kwargs"] == nil)
        let llamaOn = try await sent(.llamaCpp, think: true), llamaOff = try await sent(.llamaCpp, think: false)
        #expect((llamaOn["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true && llamaOn["reasoning_effort"] == nil)
        #expect((llamaOff["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        for think in [true, false] {
            let left = try await sent(nil, think: think)
            #expect(left["reasoning_effort"] == nil && left["chat_template_kwargs"] == nil)
        }
        // Oatcake's own Qwen is told as before, and never in Ollama's way.
        let qwen3 = try #require(LocalModels.find("qwen3-8b"))
        _ = try await LocalChat(baseUrl: server.address + "/v1", model: "qwen3-8b", key: "made-up", sampling: (qwen3.thinking, qwen3.direct)).complete([ChatMessage("user", "Say OK.")], think: false)
        let qwen = try #require(server.requests.last).json
        #expect((qwen["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false && qwen["reasoning_effort"] == nil)

        // Settings: read on its own, and a value Oatcake doesn't know leaves it to the server.
        var llm = server.config.llm
        llm.own.reasoningControl = .llamaCpp
        #expect(try JSONDecoder().decode(LlmConfig.self, from: JSONEncoder().encode(llm)).own.reasoningControl == .llamaCpp)
        let unknown = try JSONDecoder().decode(LlmConfig.self, from: Data(#"{"model":"own","own":{"baseUrl":"http://localhost:11434/v1","model":"gemma4","reasoningControl":"lmstudio"}}"#.utf8))
        #expect(unknown.own.reasoningControl == nil && unknown.own.model == "gemma4")
    }

    /// Ollama answers a request to reason, sent to a model that can't, with a 400 (its words, from
    /// server/routes.go). Oatcake asks once more without reasoning_effort instead of failing the task.
    @Test func ollamaModelThatCantReason() async throws {
        let server = try await StandIn { request in
            request.json["reasoning_effort"] as? String == "medium"
                ? StandIn.Response(status: 400, body: Data(#"{"error":"\"llama3.2\" does not support thinking"}"#.utf8))
                : .chat("OK")
        }
        var own = server.config.llm.own
        own.reasoningControl = .ollama
        #expect(try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: true) == "OK")
        #expect(server.requests.count == 2 && server.requests[1].json["reasoning_effort"] == nil)
        // Turning reasoning off ("none") is never refused, so it's sent once as it is.
        #expect(try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: false) == "OK")
        #expect(server.requests.count == 3 && server.requests[2].json["reasoning_effort"] as? String == "none")
        // Any other refusal is still an error.
        let other = try await StandIn { _ in StandIn.Response(status: 400, body: Data(#"{"error":"model not found"}"#.utf8)) }
        var missing = other.config.llm.own
        missing.reasoningControl = .ollama
        await #expect(throws: OatcakeError.self) {
            try await LocalChat(own: missing).complete([ChatMessage("user", "Say OK.")], think: true)
        }
        #expect(other.requests.count == 1)
    }

    /// A model's file is carried on from where an earlier download stopped, and only kept when it's
    /// the file that was expected.
    @Test func downloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
        let server = try await StandIn { request in
            guard let range = request.headers["range"], let from = Int(range.replacingOccurrences(of: "bytes=", with: "").dropLast()) else {
                return StandIn.Response(body: content)
            }
            return StandIn.Response(status: 206, headers: ["Content-Range": "bytes \(from)-\(content.count - 1)/\(content.count)"], body: content[from...])
        }
        func model(sha256: String) -> LocalModel {
            testModel(url: server.address + "/test.gguf", sha256: sha256, bytes: Int64(content.count))
        }
        let good = model(sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
        let file = dir.appendingPathComponent("test.gguf"), part = file.appendingPathExtension("part")

        // The first third is here already: only the rest is asked for.
        try content[..<100_000].write(to: part)
        // Without room for the rest and a gigabyte to spare, it says so and asks for nothing.
        do {
            try await ModelDownload.fetch(good, to: file, available: 150_000) { _ in }
            Issue.record("downloaded without room")
        } catch {
            #expect(error.localizedDescription.contains("isn’t room") && server.requests.isEmpty)
        }
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(try Data(contentsOf: file) == content && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == "bytes=100000-")
        // It was checked as it arrived, so it isn't read again when it's first started.
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("checked").path))
        // It's here now: nothing is fetched.
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(server.requests.count == 1)

        // From nothing, and a file that isn't the one expected is thrown away.
        try FileManager.default.removeItem(at: file)
        await #expect(throws: OatcakeError.self) { try await ModelDownload.fetch(model(sha256: String(repeating: "0", count: 64)), to: file) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.last?.headers["range"] == nil)

        // Stopped before it began: it ends, and nothing is asked for.
        let asked = server.requests.count
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ModelDownload.fetch(good, to: file) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await stopped.value }
        #expect(server.requests.count == asked)
    }

    /// The model's file is read again before it's started only when its size or modification date
    /// has changed since it last passed: reading 5 GB every time would hold up every summary.
    @Test func modelFileCheckedWhenItChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let model = testModel(url: "https://example.com/test.gguf", sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
                              bytes: Int64(content.count))
        let file = dir.appendingPathComponent("test.gguf"), note = file.appendingPathExtension("checked")
        // A date to a whole second, so it can be put back exactly.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try content.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try LocalModels.verify(model, in: dir)
        #expect(FileManager.default.fileExists(atPath: note.path))

        // Other bytes of the same size with the date put back aren't noticed: that's the limit of it.
        var changed = content
        changed[0] ^= 0xff
        try changed.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try LocalModels.verify(model, in: dir)

        // A new date: it's read again, and a file that doesn't match is thrown away, to be downloaded again.
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(throws: OatcakeError.self) { try LocalModels.verify(model, in: dir) }
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: note.path))
    }

    /// llama.cpp's server isn't started when anything in the app has been changed, added or taken
    /// away since it was signed. Tried on a small app signed here, ad hoc.
    @Test func appMustBeAsSigned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-sealed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func signedApp() throws -> (app: URL, llama: URL) {
            let app = dir.appendingPathComponent("\(UUID().uuidString).app")
            let llama = app.appendingPathComponent("Contents/Resources/llama")
            try FileManager.default.createDirectory(at: llama, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "local.oatcake.test", "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            // Any program will do for one that's never run: the system's own `true`.
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Test"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: llama.appendingPathComponent("llama-server"))
            try Data("Made-up licence".utf8).write(to: llama.appendingPathComponent("LICENSE"))
            try runCapturing("/usr/bin/codesign", ["--force", "--sign", "-", llama.appendingPathComponent("llama-server").path])
            try runCapturing("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            return (app, llama)
        }
        let intact = try signedApp()
        try ModelServer.checkSealed(intact.app)

        let changed = try signedApp()
        try Data("Another licence".utf8).write(to: changed.llama.appendingPathComponent("LICENSE"))
        #expect(throws: OatcakeError.self) { try ModelServer.checkSealed(changed.app) }

        let added = try signedApp()
        try Data("Not a library".utf8).write(to: added.llama.appendingPathComponent("libextra.dylib"))
        #expect(throws: OatcakeError.self) { try ModelServer.checkSealed(added.app) }

        let removed = try signedApp()
        try FileManager.default.removeItem(at: removed.llama.appendingPathComponent("LICENSE"))
        #expect(throws: OatcakeError.self) { try ModelServer.checkSealed(removed.app) }

        // A program put in its place, signed in its own right, isn't the one the app was signed with.
        let replaced = try signedApp()
        let server = replaced.llama.appendingPathComponent("llama-server")
        try FileManager.default.removeItem(at: server)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: server)
        try runCapturing("/usr/bin/codesign", ["--force", "--sign", "-", server.path])
        #expect(throws: OatcakeError.self) { try ModelServer.checkSealed(replaced.app) }

        // The other half of the check, that the app on the disk is the copy that's running (an app
        // changed and then signed again as a whole is otherwise whole), can't be tried from here:
        // the copy running is the test runner, not an app this test can sign again. It was tried by
        // hand when written, on a small program that signed itself again on the disk.
    }

    /// llama.cpp's server keeps no copies of earlier prompts: they'd take memory a model isn't given
    /// room for. A window past the model's own is stretched, and only then.
    @Test func serverArguments() throws {
        let model = try #require(LocalModels.find("qwen3-8b"))
        let file = URL(fileURLWithPath: "/models/Qwen3-8B-Q4_K_M.gguf")
        let native = ModelServer.arguments(model, file: file, port: 8080, context: 32_768)
        let stretched = ModelServer.arguments(model, file: file, port: 8080, context: 65_536)
        for arguments in [native, stretched] {
            let cache = try #require(arguments.firstIndex(of: "--cache-ram"))
            #expect(arguments[cache + 1] == "0" && arguments.contains(file.path))
        }
        #expect(!native.contains("--rope-scaling") && stretched.contains("--rope-scaling"))
    }

    /// The model's server counts as started only once llama.cpp has said it's listening on the
    /// port it was given: before then, whatever answers there may be another program's. The lines
    /// are as the pinned build writes them.
    @Test func startedOnlyWhenLlamaListens() {
        let loaded = "srv  server_run_i: model loaded\n"
        #expect(!ModelServer.saysListening(loaded, port: 54321))
        let listening = loaded + "srv  server_on_li: listening on http://127.0.0.1:54321\n"
        #expect(ModelServer.saysListening(listening, port: 54321))
        // Another port, even one that starts the same, isn't this one.
        #expect(!ModelServer.saysListening(listening, port: 5432) && !ModelServer.saysListening(listening, port: 4321))
        // With llama.cpp's own prefix and timestamp on the line, if they're turned on.
        #expect(ModelServer.saysListening("0.02.153.441 I srv  server_on_li: listening on http://127.0.0.1:54321\n", port: 54321))
        // One that couldn't take the port says so instead.
        #expect(!ModelServer.saysListening("srv         start: couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 54321\n", port: 54321))
    }

    /// A model server of your own that answers with a redirect isn't followed: the transcript would
    /// go to an address that was never checked to be local.
    @Test func redirectsAreNotFollowed() async throws {
        let elsewhere = try await StandIn.model { _ in "OK" }
        let redirecting = try await StandIn { request in
            StandIn.Response(status: 307, headers: ["Location": elsewhere.address + request.path])
        }
        do {
            _ = try await LocalChat(baseUrl: redirecting.address + "/v1", model: "stand-in").complete([ChatMessage("user", "The transcript")])
            Issue.record("followed the redirect")
        } catch {
            #expect(error.localizedDescription.hasPrefix("The model at \(redirecting.address)/v1 returned 307"))
        }
        // Nor is one from Oatcake's own server's /health.
        let qwen3 = try #require(LocalModels.find("qwen3-8b"))
        #expect(await !LocalChat(baseUrl: redirecting.address + "/v1", model: "qwen3-8b", key: "made-up", sampling: (qwen3.thinking, qwen3.direct)).isReady())
        #expect(elsewhere.requests.isEmpty && redirecting.requests.count == 2)
    }

    /// Check it works in Settings › Models. A server of your own whose model reasons first can spend
    /// the check's few tokens on that: it answered, so the check passes. Anything else still fails.
    @Test func checkModelPassesAModelStillReasoning() async throws {
        let replying = try await StandIn.model { _ in "OK" }
        #expect(try await checkModel(replying.config.llm) == .replied("OK"))
        let sent = try #require(replying.requests.last?.json)
        #expect(sent["max_tokens"] as? Int == 20)

        let reasoning = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":"","reasoning_content":"The user wants"},"finish_reason":"length"}]}"#.utf8))
        }
        #expect(try await checkModel(reasoning.config.llm) == .stillReasoning)
        // One that simply says more than the check has room for has replied: only summaries and the
        // like need a reply that's whole.
        let wordy = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":"OK, here I am and ready to"},"finish_reason":"length"}]}"#.utf8))
        }
        #expect(try await checkModel(wordy.config.llm) == .replied("OK, here I am and ready to"))

        // An empty reply that wasn't cut off, or an error from the server, isn't working.
        let empty = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#.utf8))
        }
        await #expect(throws: OatcakeError("The model gave an empty reply.")) { _ = try await checkModel(empty.config.llm) }
        let failing = try await StandIn { _ in StandIn.Response(status: 404, body: Data(#"{"error":"model not found"}"#.utf8)) }
        await #expect(throws: OatcakeError.self) { _ = try await checkModel(failing.config.llm) }
    }
}

/// A made-up model file for the download and checksum tests, otherwise like Qwen3 4B.
private func testModel(url: String, sha256: String, bytes: Int64) -> LocalModel {
    let like = LocalModels.find("qwen3-4b")!
    return LocalModel(id: "test", title: "Test model", detail: "", file: "test.gguf", url: url, sha256: sha256, bytes: bytes,
                      baseMemory: 1, memoryPerThousandTokens: 0.1, nativeContext: like.nativeContext, thinking: like.thinking,
                      direct: like.direct, replyTokens: like.replyTokens, legacy: false, reasoning: like.reasoning)
}
