import Foundation

// Spacefast's API, as far as sharing needs it: publishing pages to one Space and saying who can
// read which of them. Every request carries the key you gave Oatcake for that Space.

public struct Spacefast: Sendable {
    public var space: String
    var key: String
    var base: URL

    public init(space: String, key: String, base: URL = URL(string: "https://api.spacefast.com")!) {
        self.space = space.trimmed
        self.key = key.trimmed
        self.base = base
    }

    public struct SpaceInfo: Equatable, Sendable {
        public var id: String
        public var name: String
        /// Where its pages are served.
        public var address: String
    }

    private func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, contentType: String? = nil) async throws -> Any? {
        guard !space.isEmpty, !key.isEmpty else { throw OatcakeError("Set your Space and its key in Settings › Sharing first.") }
        guard let url = URL(string: path, relativeTo: base) else { throw OatcakeError("That isn’t a valid Space.") }
        // The key goes nowhere but Spacefast, and never in the clear (a test server on this Mac aside).
        guard url.scheme == "https" || ["127.0.0.1", "localhost"].contains(url.host ?? "") else { throw OatcakeError("Spacefast is only reached over HTTPS.") }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("Oatcake", forHTTPHeaderField: "user-agent")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status) else {
            // Spacefast says what went wrong as {"code", "message"}, sometimes inside "error".
            let problem = (parsed as? [String: Any]).map { $0["error"] as? [String: Any] ?? $0 }
            let message = problem?["message"] as? String ?? problem?["detail"] as? String ?? problem?["title"] as? String
            switch status {
            case 401: throw OatcakeError("Spacefast didn’t accept the key. Check it in Settings › Sharing.")
            case 403: throw OatcakeError("The key isn’t allowed to do that on this Space\(message.map { ": \($0)" } ?? ".")")
            case 404: throw OatcakeError("Spacefast has no Space called “\(space)” that this key can reach.")
            default: throw OatcakeError("Spacefast returned \(status)\(message.map { ": \($0)" } ?? ".")")
            }
        }
        return (parsed as? [String: Any])?["data"]
    }

    private var spacePath: String { "/v1/spaces/" + (space.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? space) }

    public func info() async throws -> SpaceInfo {
        let data = try await call("GET", spacePath) as? [String: Any] ?? [:]
        return SpaceInfo(id: data["id"] as? String ?? space, name: data["title"] as? String ?? data["slug"] as? String ?? space,
                         address: data["liveUrl"] as? String ?? "")
    }

    /// Everyone given access to the Space by name, with the addresses they can read now.
    public func people() async throws -> [SharePerson] {
        let list = try await call("GET", spacePath + "/people") as? [[String: Any]] ?? []
        return list.compactMap { person in
            guard let id = person["id"] as? String, person["status"] as? String != "revoked" else { return nil }
            let grants = person["grants"] as? [[String: Any]] ?? []
            let scopes = grants.filter { $0["revokedAt"] == nil || $0["revokedAt"] is NSNull }.compactMap { $0["scope"] as? String }
            return SharePerson(id: id, email: person["email"] as? String ?? "", scopes: scopes)
        }
    }

    private func grants(_ scopes: [String]) -> [[String: String]] { scopes.map { ["scope": $0, "role": "viewer"] } }

    /// Spacefast emails them a link; they need no account.
    public func invite(_ email: String, scopes: [String]) async throws {
        _ = try await call("POST", spacePath + "/people", json: ["email": email, "grants": grants(scopes)])
    }

    /// Replaces what a person can read with exactly these addresses.
    public func setScopes(_ person: String, _ scopes: [String]) async throws {
        _ = try await call("PUT", spacePath + "/people/\(person)/roles", json: ["grants": grants(scopes)])
    }

    public func remove(_ person: String) async throws {
        _ = try await call("DELETE", spacePath + "/people/\(person)")
    }

    /// Links that open the Space to whoever holds them, by id.
    public func links() async throws -> [String] {
        let list = try await call("GET", spacePath + "/share-links") as? [[String: Any]] ?? []
        return list.filter { ($0["active"] as? Bool) != false && ($0["revokedAt"] == nil || $0["revokedAt"] is NSNull) }.compactMap { $0["id"] as? String }
    }

    public func revokeLink(_ id: String) async throws {
        _ = try await call("DELETE", spacePath + "/share-links/\(id)")
    }

    /**
     * Makes the Space's pages exactly these files: anything published before and not among them is
     * gone from the live site. One request, a part for each file and one saying what to do with them.
     */
    public func publish(_ files: [SiteFile], message: String) async throws {
        let id = try await info().id
        let boundary = "oatcake-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, filename: String?, type: String, _ data: Data) {
            // A name or filename can't break out of its header: quotes and line breaks are taken out.
            let safe = { (text: String) in text.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safe(name))\"\(filename.map { "; filename=\"\(safe($0))\"" } ?? "")\r\nContent-Type: \(type)\r\n\r\n".utf8)
            body += data
            body += Data("\r\n".utf8)
        }
        let payload: [String: Any] = ["spaceId": id, "publishMode": "snapshot", "source": ["kind": "api", "client": "Oatcake", "message": message]]
        part("payload", filename: nil, type: "application/json", try JSONSerialization.data(withJSONObject: payload))
        for file in files {
            part(file.path, filename: file.path, type: file.path.hasSuffix(".html") ? "text/html; charset=utf-8" : "application/octet-stream", file.data)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        _ = try await call("POST", "/v1/publish", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

/// What a sync did, for the window to say.
public struct SharingReport: Equatable, Sendable {
    public var pages = 0
    public var invited: [String] = []
    public var removed = 0
    /// Synced folders that had gone from the Meetings folder, and so stopped syncing.
    public var forgotten: [String] = []
}

/**
 * Brings the Space into line with the synced folders, in an order that never shows anyone more
 * than they should see: folders that have gone are forgotten, then access is taken away, then the
 * pages are published, then the links publishing makes are revoked, and only then is new access
 * given. If any step fails, the ones after it don't happen.
 */
public func syncSharing(_ state: inout SharingState, meetings: Meetings, spacefast: Spacefast, owner: String) async throws -> SharingReport {
    var report = SharingReport()
    let tree = meetings.tree()
    report.forgotten = state.forgetMissing(in: tree)
    // Worked out before anything is sent, so two folders wanting one address stop the sync here.
    let files = try sharedSite(state, meetings: meetings, tree: tree, owner: owner)

    let plan = sharingPlan(state, people: try await spacefast.people(), links: try await spacefast.links())
    for link in plan.before.revokeLinks { try await spacefast.revokeLink(link) }
    for person in plan.before.remove { try await spacefast.remove(person) }
    for (person, scopes) in plan.before.narrow.sorted(by: { $0.key < $1.key }) { try await spacefast.setScopes(person, scopes) }
    report.removed = plan.before.remove.count

    try await spacefast.publish(files, message: "Oatcake: \(files.count - 1) page\(files.count == 2 ? "" : "s")")
    report.pages = files.count - 1
    // Publishing can leave a link that opens the whole Space.
    for link in try await spacefast.links() { try await spacefast.revokeLink(link) }

    for (person, scopes) in plan.after.widen.sorted(by: { $0.key < $1.key }) { try await spacefast.setScopes(person, scopes) }
    for (email, scopes) in plan.after.invite.sorted(by: { $0.key < $1.key }) {
        try await spacefast.invite(email, scopes: scopes)
        report.invited.append(email)
    }
    return report
}
