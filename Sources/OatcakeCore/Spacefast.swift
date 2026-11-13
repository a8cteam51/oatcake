import CryptoKit
import Foundation

// Spacefast's API, as far as sharing needs it: making your Space, publishing pages to it and saying
// who can read which of them. Every request carries your sign-in (see SpacefastSignIn).

public struct Spacefast: Sendable {
    public var space: String
    /// What each request is sent with: the sign-in, renewed if it has to be.
    var token: @Sendable () async throws -> String
    var base: URL

    /// As whoever is signed in. `space` is empty until there is one.
    public init(space: String = "", session: SpacefastSession, base: URL? = nil) {
        self.space = space.trimmed
        token = { try await session.token() }
        self.base = base ?? SpacefastAccount.api
    }

    /// With a key that's sent as it is.
    public init(space: String, key: String, base: URL? = nil) {
        self.space = space.trimmed
        let key = key.trimmed
        token = {
            guard !key.isEmpty else { throw OatcakeError("Sign in to Spacefast in Settings › Sharing first.") }
            return key
        }
        self.base = base ?? SpacefastAccount.api
    }

    /// For trying sharing without Spacefast: OATCAKE_SPACEFAST_API names a stand-in on this Mac (for signing in too). Anywhere else is ignored.
    static let testServer: URL? = ProcessInfo.processInfo.environment["OATCAKE_SPACEFAST_API"].flatMap(URL.init(string:)).flatMap {
        ["127.0.0.1", "localhost"].contains($0.host ?? "") ? $0 : nil
    }

    public struct SpaceInfo: Equatable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// Where its pages are served.
        public var address: String
    }

    private func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, contentType: String? = nil, onSpace: Bool = true) async throws -> Any? {
        try await send(method, path, json: json, body: body, contentType: contentType, onSpace: onSpace)?["data"]
    }

    /// The whole of Spacefast's answer: what was asked for is in "data", and a list says in "pagination" whether there's more.
    private func send(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, contentType: String? = nil, onSpace: Bool = true) async throws -> [String: Any]? {
        guard !onSpace || !space.isEmpty else { throw OatcakeError("Make your Oatcake Space in Settings › Sharing first.") }
        guard let url = URL(string: path, relativeTo: base) else { throw OatcakeError("That isn’t a valid Space.") }
        // The sign-in goes nowhere but Spacefast, and never in the clear (a test server on this Mac aside).
        guard url.scheme == "https" || ["127.0.0.1", "localhost"].contains(url.host ?? "") else { throw OatcakeError("Spacefast is only reached over HTTPS.") }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "authorization")
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
            case 401: throw OatcakeError("Spacefast didn’t accept your sign-in. Sign out and in again in Settings › Sharing.")
            case 403: throw OatcakeError("Your sign-in isn’t allowed to do that on Spacefast\(message.map { ": \($0)" } ?? ".")")
            case 404 where onSpace: throw OatcakeError("Your Oatcake Space isn’t on Spacefast any more, or this sign-in can’t reach it.")
            default: throw OatcakeError("Spacefast returned \(status)\(message.map { ": \($0)" } ?? ".")")
            }
        }
        return parsed as? [String: Any]
    }

    private var spacePath: String { "/v1/spaces/" + (space.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? space) }

    public func info() async throws -> SpaceInfo {
        info(from: try await call("GET", spacePath) as? [String: Any] ?? [:])
    }

    private func info(from data: [String: Any]) -> SpaceInfo {
        SpaceInfo(id: data["id"] as? String ?? space, name: data["title"] as? String ?? data["slug"] as? String ?? space,
                  address: data["liveUrl"] as? String ?? "")
    }

    /// A team on Spacefast you can make a Space in.
    public struct Team: Equatable, Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
    }

    /// The teams the sign-in can act for, as Spacefast lists them.
    public func teams() async throws -> [Team] {
        let list = try await call("GET", "/v1/teams?limit=100", onSpace: false) as? [[String: Any]] ?? []
        return list.compactMap { team in
            guard let id = team["id"] as? String else { return nil }
            return Team(id: id, name: team["name"] as? String ?? team["slug"] as? String ?? id)
        }
    }

    /// The Spaces a team already has, most recently changed first.
    public func spaces(in team: String) async throws -> [SpaceInfo] {
        let path = "/v1/teams/" + (team.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? team) + "/spaces?limit=100"
        var found: [SpaceInfo] = []
        var cursor: String?
        // A page at a time, and no more than a thousand: nobody picks from a longer list.
        for _ in 0..<10 {
            let page = try await send("GET", path + (cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? ""), onSpace: false)
            for space in page?["data"] as? [[String: Any]] ?? [] where space["id"] is String { found.append(info(from: space)) }
            cursor = (page?["pagination"] as? [String: Any])?["nextCursor"] as? String
            if cursor == nil { break }
        }
        return found
    }

    /// Makes a Space called Oatcake in a team: private, and with no link that opens it.
    public func createSpace(team: String) async throws -> SpaceInfo {
        let made = try await call("POST", "/v1/spaces", json: ["teamId": team, "title": "Oatcake", "access": "private", "capabilities": ["optional_access"]], onSpace: false)
        guard let space = (made as? [String: Any])?["space"] as? [String: Any], let id = space["id"] as? String, !id.isEmpty else {
            throw OatcakeError("Spacefast didn’t say what Space it made.")
        }
        return info(from: space)
    }

    /// The team that owns the Space. Everyone in it can read all of the Space, whatever is set here.
    public struct OwningTeam: Equatable, Sendable {
        public var name: String
        public var members: Int
    }

    /// Everyone given access to the Space by name, with the addresses they can read now, and the team that owns it.
    public func access() async throws -> (people: [SharePerson], team: OwningTeam?) {
        let data = try await call("GET", spacePath + "/people")
        // {"people": […], "inheritedTeamAccess": {"teamName", "members": […]}}
        let list = (data as? [String: Any])?["people"] as? [[String: Any]] ?? data as? [[String: Any]] ?? []
        let inherited = (data as? [String: Any])?["inheritedTeamAccess"] as? [String: Any]
        let team = inherited.map { OwningTeam(name: $0["teamName"] as? String ?? "", members: ($0["members"] as? [Any])?.count ?? 0) }
        return (people(from: list), team)
    }

    public func people() async throws -> [SharePerson] { try await access().people }

    private func people(from list: [[String: Any]]) -> [SharePerson] {
        list.compactMap { person in
            guard let id = person["id"] as? String, person["status"] as? String != "revoked" else { return nil }
            let grants = person["grants"] as? [[String: Any]] ?? []
            // Spacefast gives a folder's address back without its closing slash ("/clients" for "/clients/").
            let scopes = grants.filter { $0["revokedAt"] == nil || $0["revokedAt"] is NSNull }.compactMap { $0["scope"] as? String }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
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
    /// Nothing had changed since the last sync, so Spacefast wasn't contacted.
    public var unchanged = false
}

/// What a sync would leave on the Space: every page, and who reads what.
func shareFingerprint(_ files: [SiteFile], _ state: SharingState) -> String {
    var hash = SHA256()
    for file in files {
        hash.update(data: Data(file.path.utf8))
        hash.update(data: Data(SHA256.hash(data: file.data)))
    }
    for (email, scopes) in wantedScopes(state).sorted(by: { $0.key < $1.key }) { hash.update(data: Data("\(email)=\(scopes.joined(separator: ","))\n".utf8)) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/**
 * Brings the Space into line with the synced folders, in an order that never shows anyone more
 * than they should see: folders that have gone are forgotten, then access is taken away, then the
 * pages are published, then the links publishing makes are revoked, and only then is new access
 * given. If any step fails, the ones after it don't happen.
 *
 * When the pages and readers are what the last sync left, nothing is sent, unless `always` is set
 * (which also puts right anything changed on Spacefast itself).
 */
public func syncSharing(_ state: inout SharingState, meetings: Meetings, spacefast: Spacefast, owner: String, always: Bool = false) async throws -> SharingReport {
    var report = SharingReport()
    // A Meetings folder that isn't there (a drive not connected, say) is not a Meetings folder with
    // nothing in it: syncing now would take every folder off the Space and every reader with it.
    guard FileManager.default.isDirectory(meetings.root) else { throw OatcakeError("Your Meetings folder isn’t available, so nothing was synced.") }
    let tree = meetings.tree()
    report.forgotten = state.forgetMissing(in: tree)
    // Worked out before anything is sent, so two folders wanting one address stop the sync here.
    let files = try sharedSite(state, meetings: meetings, tree: tree, owner: owner)
    let fingerprint = shareFingerprint(files, state)
    if !always, fingerprint == state.published {
        report.unchanged = true
        return report
    }
    // Until this sync has finished, the Space isn't known to match anything.
    state.published = nil

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
    state.published = fingerprint
    return report
}
