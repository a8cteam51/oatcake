import Foundation

// Sharing: some folders of meetings are kept on a Spacefast Space of your own, as pages other
// people can be given access to, folder by folder. Nothing is shared unless a folder is set to
// sync, and a synced folder is readable by nobody but you until you name someone.
//
// Access on Spacefast belongs to a path, not to a folder. So the rules here err towards taking
// access away: a folder that is renamed or moved keeps syncing but loses its readers, a synced
// folder that's no longer where it was loses both, and on every sync access is taken away before
// anything is published and given only afterwards.

/// Someone a folder is shared with.
public struct ShareReader: Codable, Equatable, Hashable, Sendable {
    public var email: String
    public var name: String
    public init(email: String, name: String = "") {
        self.email = email.trimmed.lowercased()
        self.name = name.trimmed
    }
}

/// A synced folder's settings. They cover the folders inside it too.
public struct FolderSharing: Codable, Equatable, Sendable {
    /// Transcripts are published as well as summaries and to-dos.
    public var transcript = false
    /// Who can read this folder and everything in it.
    public var readers: [ShareReader] = []
    public init(transcript: Bool = false, readers: [ShareReader] = []) {
        self.transcript = transcript
        self.readers = readers
    }
}

public struct SharingState: Codable, Equatable, Sendable {
    /// The Space the folders are published to: its id (spc_…) or its name.
    public var space = ""
    /// Synced folders, by their path in the Meetings folder. A folder inside one of these is synced with it.
    public var folders: [String: FolderSharing] = [:]
    public var lastSync: String?
    public var lastError: String?
    /// A fingerprint of what the last sync left on the Space (pages and readers): a sync that would
    /// leave the same again has nothing to do.
    public var published: String?
    /// Where the Space's pages are served, learnt when it's checked: for showing a folder's address.
    public var address: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        space = (try? c.decodeIfPresent(String.self, forKey: .space)) ?? ""
        folders = (try? c.decodeIfPresent([String: FolderSharing].self, forKey: .folders)) ?? [:]
        lastSync = try? c.decodeIfPresent(String.self, forKey: .lastSync)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        published = try? c.decodeIfPresent(String.self, forKey: .published)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
    }

    public static func load(from file: URL = Paths.sharing) -> SharingState { tryJSON(SharingState.self, file) ?? SharingState() }

    public func save(to file: URL = Paths.sharing) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(self) + "\n")
    }

    /// The synced folder a path is in (itself, or the nearest one above it), if any.
    public func syncedFolder(over path: String) -> String? {
        var at = path
        while true {
            if folders[at] != nil { return at }
            guard let slash = at.lastIndex(of: "/") else { return nil }
            at = String(at[..<slash])
        }
    }

    public func isSynced(_ path: String) -> Bool { syncedFolder(over: path) != nil }

    /// Everyone who can read what's at a path: the readers of each synced folder it's in.
    public func readers(of path: String) -> [ShareReader] {
        var seen = Set<String>(), out: [ShareReader] = []
        for (folder, sharing) in folders.sorted(by: { $0.key < $1.key }) where path == folder || path.hasPrefix(folder + "/") {
            for reader in sharing.readers where seen.insert(reader.email).inserted { out.append(reader) }
        }
        return out
    }

    /// Who would newly be able to read something if it were moved into `folder`: asked before the move.
    public func readersGained(moving path: String, into folder: String) -> [ShareReader] {
        let already = Set(readers(of: path).map(\.email))
        return readers(of: folder).filter { !already.contains($0.email) }
    }

    /**
     * A folder was renamed or moved inside Oatcake. It goes on syncing where it now is, and so do
     * synced folders inside it, but nobody is carried over as a reader: the people a path was
     * shared with are added again by hand.
     */
    public mutating func folderMoved(from old: String, to new: String) {
        guard old != new else { return }
        var moved: [String: FolderSharing] = [:]
        for (path, sharing) in folders where path == old || path.hasPrefix(old + "/") {
            folders[path] = nil
            moved[new + path.dropFirst(old.count)] = FolderSharing(transcript: sharing.transcript)
        }
        // Anything already set where it lands stays as it is.
        for (path, sharing) in moved where folders[path] == nil { folders[path] = sharing }
    }

    /// Synced folders that are no longer in the Meetings folder (renamed or moved in Finder, or
    /// deleted) stop syncing and lose their readers. Returns their paths.
    @discardableResult
    public mutating func forgetMissing(in tree: TreeNode) -> [String] {
        let present = Set(tree.allFolders.map(\.path))
        let missing = folders.keys.filter { !present.contains($0) }.sorted()
        for path in missing { folders[path] = nil }
        return missing
    }
}

// MARK: - Where things go on the Space

/// A folder or meeting's name as one piece of an address: lower-case letters, digits and hyphens.
/// Plain, so that the same address can't be read two ways when access is granted on it.
public func shareSlug(_ name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
    var out = ""
    for scalar in latin.lowercased().unicodeScalars {
        if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out += "-" }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return out.isEmpty ? "folder" : String(out.prefix(80))
}

/// A folder's address on the Space, from its path in the Meetings folder: "Clients/Acme Corp" → "clients/acme-corp".
public func sharePath(_ folder: String) -> String {
    folder.split(separator: "/").map { shareSlug(String($0)) }.joined(separator: "/")
}

/// What a reader is granted for a folder: the folder's address and everything under it.
public func shareScope(_ folder: String) -> String { "/" + sharePath(folder) + "/" }

public struct SiteFile: Equatable, Sendable {
    /// Its address on the Space, without a leading slash.
    public var path: String
    public var data: Data
}

/**
 * The pages for every synced folder: one for each folder, listing what's in it, and one for each
 * meeting. A page links only downwards and to the folders above it, never sideways, and carries its
 * own styling, because a reader given one folder can fetch nothing outside it.
 *
 * Throws when two folders would get the same address: publishing either could put it in front of
 * the other's readers.
 */
public func sharedSite(_ state: SharingState, meetings: Meetings, tree: TreeNode, owner: String) throws -> [SiteFile] {
    var files: [SiteFile] = []
    var taken: [String: String] = [:]   // address → the folder that has it
    // Synced folders that aren't inside another: each is walked with everything in it.
    let roots = state.folders.keys.sorted().filter { path in !state.folders.keys.contains { $0 != path && path.hasPrefix($0 + "/") } }

    func page(_ title: String, crumbs: [(name: String, up: Int)], _ body: String) -> Data {
        let trail = crumbs.isEmpty ? "" : "<nav>" + crumbs.map { "<a href=\"\(String(repeating: "../", count: $0.up))\">\(escapeHTML($0.name))</a>" }.joined(separator: " › ") + "</nav>"
        return Data("""
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex, nofollow"><title>\(escapeHTML(title))</title><style>\(shareStyle)</style></head>
            <body><main>\(trail)<h1>\(escapeHTML(title))</h1>\(body)<footer>Shared from Oatcake by \(escapeHTML(owner)).</footer></main></body></html>

            """.utf8)
    }

    func addFolder(_ node: TreeNode, root: String, crumbs: [String]) throws {
        let address = sharePath(node.path)
        if let other = taken[address], other != node.path {
            throw OatcakeError("“\(other)” and “\(node.path)” would be shared at the same address (\(address)). Rename one of them.")
        }
        taken[address] = node.path
        let sharing = state.folders[state.syncedFolder(over: node.path) ?? root] ?? FolderSharing()
        // The folders above this one, back to the top of what's synced: links a reader of this folder alone can't follow, and no more than its address already says.
        let trail = crumbs.enumerated().map { (name: $1, up: crumbs.count - $0) }

        var used = Set(node.subfolders.map { shareSlug($0.name) })
        var rows = ""
        for folder in node.subfolders {
            rows += "<li class=\"folder\"><a href=\"\(shareSlug(folder.name))/\">\(escapeHTML(folder.name))</a></li>"
        }
        for meeting in node.meetings {
            // A meeting named like a folder beside it, or like another meeting, gets a number.
            var slug = shareSlug(meeting.name), n = 2
            while !used.insert(slug).inserted { slug = shareSlug(meeting.name) + "-\(n)"; n += 1 }
            let title = meeting.title ?? meeting.name
            let when = meeting.startedAt.map(shareDate) ?? ""
            rows += "<li><a href=\"\(slug)/\">\(escapeHTML(title))</a><span>\(escapeHTML(when))</span>"
                + (meeting.preview.isEmpty ? "" : "<p>\(escapeHTML(meeting.preview))</p>") + "</li>"
            files.append(SiteFile(path: "\(address)/\(slug)/index.html",
                                  data: page(title, crumbs: trail.map { ($0.name, $0.up + 1) } + [(node.name, 1)],
                                             meetingBody(try meetings.read(meeting.path), started: meeting.startedAt, transcript: sharing.transcript))))
        }
        files.append(SiteFile(path: "\(address)/index.html",
                              data: page(node.name, crumbs: trail, rows.isEmpty ? "<p class=\"empty\">Nothing here yet.</p>" : "<ul class=\"list\">\(rows)</ul>")))
        for folder in node.subfolders { try addFolder(folder, root: root, crumbs: crumbs + [node.name]) }
    }

    for root in roots {
        guard let node = tree.find(root), node.kind == .folder else { continue }
        try addFolder(node, root: root, crumbs: [])
    }
    // The front page says nothing of what's here: only you can open it, but it costs nothing to keep quiet.
    files.append(SiteFile(path: "index.html", data: page("Shared notes", crumbs: [], "<p class=\"empty\">Open the link you were sent to a folder.</p>")))
    return files.sorted { $0.path < $1.path }
}

private func shareDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = gregorian
    formatter.dateFormat = "EEE, MMM d, yyyy · HH:mm"
    return formatter.string(from: date)
}

/// A meeting's page: who and when, its to-dos, its summary, and its transcript when the folder shares those.
private func meetingBody(_ files: MeetingFiles, started: Date?, transcript: Bool) -> String {
    var out = ""
    let people = (files.meta.participants ?? []).joined(separator: ", ")
    let line = [started.map(shareDate), people.isEmpty ? nil : people].compactMap { $0 }.joined(separator: " · ")
    if !line.isEmpty { out += "<p class=\"meta\">\(escapeHTML(line))</p>" }
    let todos = parseTodos(files.todo)
    if !todos.isEmpty {
        out += "<h2>To-dos</h2><ul class=\"todos\">" + todos.map { todo in
            let detail = [todo.owner, todo.due.isEmpty ? "" : "due \(todo.due)"].filter { !$0.isEmpty }.joined(separator: " · ")
            return "<li class=\"\(todo.done ? "done" : "open")\"><b>\(escapeHTML(todo.text))</b>" + (detail.isEmpty ? "" : "<span>\(escapeHTML(detail))</span>") + "</li>"
        }.joined() + "</ul>"
    }
    let summary = forReading(files.summary).trimmed
    out += summary.isEmpty ? "<p class=\"empty\">No summary yet.</p>" : markdownHTML(summary)
    if transcript, !files.transcript.trimmed.isEmpty {
        out += "<h2>Transcript</h2><div class=\"transcript\">\(markdownHTML(forReading(files.transcript)))</div>"
    }
    return out
}

private let shareStyle = """
    :root{color-scheme:light dark;--ink:#1d1d1f;--soft:#6e6e73;--line:#d2d2d7;--paper:#fff;--tint:#b7791f}
    @media(prefers-color-scheme:dark){:root{--ink:#f5f5f7;--soft:#a1a1a6;--line:#3a3a3c;--paper:#1c1c1e;--tint:#e0a94a}}
    body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:720px;margin:0 auto;padding:32px 20px 64px}
    nav{font-size:14px;color:var(--soft);margin-bottom:8px}a{color:var(--tint)}nav a{color:var(--soft)}
    h1{font-size:28px;line-height:1.2;margin:0 0 6px}h2{font-size:19px;margin:30px 0 8px}h3,h4{font-size:16px;margin:22px 0 6px}
    .meta,.empty,footer,li span{color:var(--soft)}.meta{margin:0 0 20px}
    .list{list-style:none;padding:0;margin:20px 0}.list li{padding:12px 0;border-top:1px solid var(--line)}
    .list li a{font-weight:600;text-decoration:none}.list li span{float:right;font-size:14px}.list li p{margin:4px 0 0;color:var(--soft);font-size:15px}
    .list .folder a::before{content:"▸ "}
    .todos{list-style:none;padding:0}.todos li{padding:4px 0 4px 26px;position:relative}.todos li::before{content:"○";position:absolute;left:4px;color:var(--soft)}
    .todos b{font-weight:400}.todos .done b{color:var(--soft);text-decoration:line-through}.todos .done::before{content:"●"}.todos span{display:block;font-size:14px}
    blockquote{margin:12px 0;padding-left:14px;border-left:3px solid var(--line);color:var(--soft)}
    pre{overflow:auto;padding:12px;border:1px solid var(--line);border-radius:6px;font-size:14px}code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}
    table{border-collapse:collapse;margin:12px 0}th,td{border:1px solid var(--line);padding:5px 10px;text-align:left}
    hr{border:0;border-top:1px solid var(--line);margin:24px 0}.transcript p{margin:10px 0}
    footer{margin-top:48px;padding-top:14px;border-top:1px solid var(--line);font-size:13px}
    """

// MARK: - Who can read what

/// Someone with access on the Space, as Spacefast lists them.
public struct SharePerson: Equatable, Sendable {
    public var id: String
    public var email: String
    /// The addresses they can read.
    public var scopes: [String]
    public init(id: String, email: String, scopes: [String]) {
        self.id = id
        self.email = email.lowercased()
        self.scopes = scopes
    }
}

/// What has to change on the Space so that the people who can read it are exactly the readers
/// set here. `before` is done ahead of publishing and only takes access away; `after` only gives it.
public struct SharingPlan: Equatable, Sendable {
    public struct Before: Equatable, Sendable {
        public var remove: [String] = []                          // people, by id
        public var narrow: [String: [String]] = [:]               // person id → the scopes they keep
        public var revokeLinks: [String] = []
    }
    public struct After: Equatable, Sendable {
        public var invite: [String: [String]] = [:]               // email → scopes
        public var widen: [String: [String]] = [:]                // person id → all their scopes
    }
    public var before = Before()
    public var after = After()
}

/// Each reader's scopes: one for every folder they're named on, less any inside another of theirs.
public func wantedScopes(_ state: SharingState) -> [String: [String]] {
    var wanted: [String: Set<String>] = [:]
    for (folder, sharing) in state.folders {
        for reader in sharing.readers where !reader.email.isEmpty { wanted[reader.email, default: []].insert(shareScope(folder)) }
    }
    return wanted.mapValues { scopes in scopes.filter { scope in !scopes.contains { $0 != scope && scope.hasPrefix($0) } }.sorted() }
}

public func sharingPlan(_ state: SharingState, people: [SharePerson], links: [String]) -> SharingPlan {
    let wanted = wantedScopes(state)
    var plan = SharingPlan()
    // Oatcake shares with people, never by link: a link on the Space (publishing makes one) goes.
    plan.before.revokeLinks = links.sorted()
    var known = Set<String>()
    for person in people {
        known.insert(person.email)
        let want = wanted[person.email] ?? []
        let keep = person.scopes.filter(want.contains).sorted()
        if keep.isEmpty {
            // Nothing they have is still theirs. If something new is, they're invited afresh once it's published.
            plan.before.remove.append(person.id)
            if !want.isEmpty { plan.after.invite[person.email] = want }
        } else {
            if keep != person.scopes.sorted() { plan.before.narrow[person.id] = keep }
            if keep != want { plan.after.widen[person.id] = want }
        }
    }
    for (email, scopes) in wanted where !known.contains(email) { plan.after.invite[email] = scopes }
    plan.before.remove.sort()
    return plan
}
