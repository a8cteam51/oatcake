import CryptoKit
import Foundation
import Network

// Signing in to Spacefast from the app. Oatcake opens Spacefast's sign-in page in your browser;
// when you approve, the browser is sent back to an address on this Mac that Oatcake listens on for
// that one answer, and Oatcake swaps what arrives for a sign-in it keeps in your Keychain. No key
// is made or pasted, and no secret of Oatcake's own is involved: the app proves each sign-in is
// the one it started (PKCE).

public enum SpacefastAccount {
    /// Who Oatcake is to Spacefast: the address of a public file that names the app and where a
    /// sign-in may be sent back to. If this address changes, everyone signs in again.
    public static let client = "https://a8cteam51.github.io/oatcake/oauth/client.json"
    /// Seeing your teams, making and reading Spaces, publishing, and staying signed in.
    static let scopes = "teams:read spaces:read spaces:write publish:write offline_access"

    static var api: URL { Spacefast.testServer ?? URL(string: "https://api.spacefast.com")! }
    static func issuer(_ base: URL) -> String { base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/auth" }
    static func endpoint(_ name: String, _ base: URL) -> URL { URL(string: issuer(base) + "/oauth2/" + name)! }

    /// Spacefast refused the request itself (a code or sign-in that's no longer good), as opposed to not being reachable.
    struct Refused: Error { var reason: String; var detail: String }

    /// Asks Spacefast's token address for a sign-in, with a one-time code or with the last sign-in's renewal.
    static func tokens(_ fields: [String: String], base: URL) async throws -> SpacefastTokens {
        let url = endpoint("token", base)
        guard url.scheme == "https" || ["127.0.0.1", "localhost"].contains(url.host ?? "") else { throw OatcakeError("Spacefast is only reached over HTTPS.") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Oatcake", forHTTPHeaderField: "user-agent")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // In a form, + means a space: one inside a value is spelled out.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let access = reply["access_token"] as? String, !access.isEmpty else {
            if (400..<500).contains(status), let reason = reply["error"] as? String {
                throw Refused(reason: reason, detail: reply["error_description"] as? String ?? reason)
            }
            throw OatcakeError("Spacefast returned \(status) when signing in.")
        }
        let seconds = (reply["expires_in"] as? NSNumber)?.doubleValue
        return SpacefastTokens(access: access, refresh: reply["refresh_token"] as? String, expires: seconds.map { Date().addingTimeInterval($0) })
    }
}

/// A sign-in: what requests carry, what renews it, and when it needs renewing.
public struct SpacefastTokens: Codable, Equatable, Sendable {
    public var access: String
    public var refresh: String?
    /// nil for one that doesn't run out.
    public var expires: Date?

    public init(access: String, refresh: String? = nil, expires: Date? = nil) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
    }

    /// As kept in the Keychain. Anything there that isn't a sign-in is taken as a key to send as it is
    /// (OATCAKE_SPACEFAST_KEY in the environment, for running without a browser).
    init?(saved: String) {
        let text = saved.trimmed
        guard !text.isEmpty else { return nil }
        if let tokens = try? JSONDecoder().decode(SpacefastTokens.self, from: Data(text.utf8)) { self = tokens } else { self.init(access: text) }
    }

    var saved: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// The sign-in Oatcake holds, renewed as it runs out. Spacefast replaces the renewal each time it's
/// used, so there is one of these for the app and each renewal is saved before it's relied on.
public actor SpacefastSession {
    private var tokens: SpacefastTokens?
    private let save: @Sendable (String) throws -> Void
    private let base: URL
    private var renewing: Task<SpacefastTokens, Error>?
    /// Whether a sign-in was saved when Oatcake started.
    public nonisolated let startedSignedIn: Bool

    /// The saved sign-in is read from the Keychain once, here.
    public init(saved: String = Secrets.get(.spacefast), save: @escaping @Sendable (String) throws -> Void = { try Secrets.set(.spacefast, $0) }, base: URL? = nil) {
        tokens = SpacefastTokens(saved: saved)
        startedSignedIn = tokens != nil
        self.save = save
        self.base = base ?? SpacefastAccount.api
    }

    public var signedIn: Bool { tokens != nil }

    /// Keeps a new sign-in. One that can't be saved isn't kept: it would be gone at the next launch.
    public func signIn(_ new: SpacefastTokens) throws {
        try save(new.saved)
        tokens = new
    }

    public func signOut() {
        tokens = nil
        try? save("")
    }

    /// What to send with a request, renewed first if it's about to run out.
    public func token() async throws -> String {
        guard let held = tokens else { throw OatcakeError("Sign in to Spacefast in Settings › Sharing first.") }
        guard let expires = held.expires, expires.timeIntervalSinceNow < 60 else { return held.access }
        guard let refresh = held.refresh else {
            signOut()
            throw OatcakeError("Your Spacefast sign-in has run out. Sign in again in Settings › Sharing.")
        }
        // Two requests at once renew once: the renewal only works a single time.
        if let renewing { return try await renewing.value.access }
        let base = base
        let task = Task { try await SpacefastAccount.tokens(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": SpacefastAccount.client], base: base) }
        renewing = task
        defer { renewing = nil }
        do {
            var fresh = try await task.value
            if fresh.refresh == nil { fresh.refresh = refresh }
            tokens = fresh
            // If the Keychain won't take it, this run carries on with it and the next launch asks for a sign-in.
            try? save(fresh.saved)
            return fresh.access
        } catch is SpacefastAccount.Refused {
            signOut()
            throw OatcakeError("Spacefast needs you to sign in again, in Settings › Sharing.")
        }
    }
}

/// One go at signing in: the page to open in the browser, and the wait for its answer.
public final class SpacefastSignIn: @unchecked Sendable {
    /// Spacefast's sign-in page for this attempt.
    public let url: URL
    private let listener: NWListener
    private let state: String
    private let verifier: String
    private let redirect: String
    private let base: URL
    private let lock = NSLock()
    private var waiting: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?

    /// Starts listening on this Mac for the browser's answer, on a port macOS picks.
    public static func start(base: URL? = nil) async throws -> SpacefastSignIn {
        let parameters = NWParameters.tcp
        // Only this Mac can reach it.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        // The attempt can't exist until the port is known, and the listener wants its handler before it starts.
        final class Later: @unchecked Sendable { weak var attempt: SpacefastSignIn? }
        let later = Later()
        listener.newConnectionHandler = { connection in
            if let attempt = later.attempt { attempt.serve(connection) } else { connection.cancel() }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw OatcakeError("Oatcake couldn’t listen for the sign-in on this Mac.")
        }
        let attempt = SpacefastSignIn(listener: listener, port: port, base: base ?? SpacefastAccount.api)
        later.attempt = attempt
        return attempt
    }

    private init(listener: NWListener, port: UInt16, base: URL) {
        self.listener = listener
        self.base = base
        state = Self.random(16)
        verifier = Self.random(48)
        redirect = "http://127.0.0.1:\(port)/callback"
        var page = URLComponents(url: SpacefastAccount.endpoint("authorize", base), resolvingAgainstBaseURL: false)!
        page.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: SpacefastAccount.client),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: SpacefastAccount.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        url = page.url!
    }

    deinit { listener.cancel() }

    static func random(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Waits for the browser to come back, then swaps what it brought for a sign-in. Gives up after `timeout`.
    public func finish(timeout: Duration = .seconds(600)) async throws -> SpacefastTokens {
        let giveUp = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.settle(.failure(OatcakeError("Nobody signed in, so Oatcake stopped waiting."))) }
        }
        defer {
            giveUp.cancel()
            listener.cancel()
        }
        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (answer: CheckedContinuation<String, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    answer.resume(with: outcome)
                } else {
                    waiting = answer
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
        do {
            return try await SpacefastAccount.tokens(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                                      "client_id": SpacefastAccount.client, "code_verifier": verifier], base: base)
        } catch let refused as SpacefastAccount.Refused {
            throw OatcakeError("Spacefast didn’t finish the sign-in: \(refused.detail)")
        }
    }

    /// Stops waiting. The page can still be open in the browser; its answer goes nowhere.
    public func cancel() {
        settle(.failure(CancellationError()))
        listener.cancel()
    }

    /// The first answer is the answer.
    private func settle(_ result: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    // MARK: - The browser's answer

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let reply = parts.count >= 2 && parts[0] == "GET" ? self.answer(to: String(parts[1])) : (status: "405 Method Not Allowed", page: "")
            let body = Data(reply.page.utf8)
            let head = "HTTP/1.1 \(reply.status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Reads the address the browser was sent back to. Anything that isn't this attempt's answer is turned away and the wait goes on.
    func answer(to target: String) -> (status: String, page: String) {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/callback" else { return ("404 Not Found", "") }
        func value(_ name: String) -> String? { url.queryItems?.first { $0.name == name }?.value }
        guard value("state") == state else { return ("400 Bad Request", Self.page("That isn’t the sign-in Oatcake is waiting for", "Go back to Oatcake and choose Sign In again.")) }
        if let error = value("error") {
            let cancelled = error == "access_denied"
            let why = cancelled ? "You didn’t approve it, so Oatcake isn’t signed in." : (value("error_description") ?? error)
            settle(.failure(OatcakeError(cancelled ? "The sign-in wasn’t approved." : "Spacefast didn’t sign you in: \(why)")))
            return ("200 OK", Self.page("Not signed in", why))
        }
        // Spacefast says who is answering; an answer from anywhere else isn't taken.
        guard let code = value("code"), !code.isEmpty, value("iss") == SpacefastAccount.issuer(base) else {
            settle(.failure(OatcakeError("The sign-in’s answer didn’t come from Spacefast, so it wasn’t used.")))
            return ("400 Bad Request", Self.page("Not signed in", "The answer didn’t come from Spacefast. Go back to Oatcake and try again."))
        }
        settle(.success(code))
        return ("200 OK", Self.page("Signed in to Spacefast", "You can close this tab and go back to Oatcake."))
    }

    static func page(_ title: String, _ text: String) -> String {
        func escaped(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>Oatcake</title>
        <body style="font: 17px -apple-system, system-ui, sans-serif; margin: 18vh auto; max-width: 26em; padding: 0 1.5em; text-align: center">
        <h1 style="font-size: 1.5em">\(escaped(title))</h1><p>\(escaped(text))</p></body></html>
        """
    }
}
