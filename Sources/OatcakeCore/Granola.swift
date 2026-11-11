// Imports Granola's export: a .zip holding one or more CSV files (or one of those CSVs), one row per
// note with document_id, document_title, document_created, summary, notes and transcript. Each note
// becomes a meeting folder (summary.md, transcript.md, notes.md when Granola kept any, meeting.json)
// under a "Granola" folder, with notes that share a title grouped in a subfolder. A note already in
// the Meetings folder (same Granola note, wherever it was moved) is skipped.

import Foundation

/// What an import did. Shared by the Granola and Quill importers.
public struct ImportResult: Sendable {
    public var imported = 0
    /// Already in the Meetings folder (the same note or meeting).
    public var skipped = 0
    /// Notes or meetings without an id or a readable date.
    public var unreadable = 0
    /// Where the new meetings went, relative to the Meetings folder.
    public var folder = granolaFolder
}

/// How far an import has got: meetings handled so far, out of how many in the export (0 of 0 while it is still being read).
public typealias ImportProgress = @Sendable (_ done: Int, _ total: Int) -> Void

public let granolaFolder = "Granola"
private let noteURL = "https://notes.granola.ai/d/"
private let requiredColumns = ["document_id", "document_title", "document_created", "summary", "transcript"]

/// RFC 4180 CSV: quoted fields may hold commas, newlines and doubled quotes.
public func parseCsv(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var chars = Array(text.unicodeScalars)[...]
    while let c = chars.popFirst() {
        if quoted {
            if c == "\"" {
                if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
            } else {
                field.unicodeScalars.append(c)
            }
        } else if c == "\"" && field.isEmpty {
            quoted = true
        } else if c == "," {
            row.append(field)
            field = ""
        } else if c == "\n" || c == "\r" {
            if c == "\r" && chars.first == "\n" { chars.removeFirst() }
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        } else {
            field.unicodeScalars.append(c)
        }
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows.filter { $0.count > 1 || $0.first != "" }
}

private func readExport(_ file: URL) throws -> [[String: String]] {
    let ext = file.pathExtension.lowercased()
    if ext == "csv" { return try readCsvs([file]) }
    guard ext == "zip" else { throw OatcakeError("Pick the .zip (or .csv) that Granola's export gave you.") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-granola-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        try runCapturing("/usr/bin/ditto", ["-x", "-k", file.path, tmp.path])
    } catch {
        throw OatcakeError("Couldn't open that .zip. Is it the file Granola's export gave you?")
    }
    var csvs: [URL] = []
    let walker = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
        if url.lastPathComponent == "__MACOSX" { walker?.skipDescendants(); continue }
        if url.pathExtension.lowercased() == "csv" { csvs.append(url) }
    }
    guard !csvs.isEmpty else { throw OatcakeError("That .zip has no CSV in it. Is it the file Granola's export gave you?") }
    return try readCsvs(csvs.sorted { $0.path < $1.path })
}

private func readCsvs(_ csvs: [URL]) throws -> [[String: String]] {
    var rows: [[String: String]] = []
    for csv in csvs {
        var text = readText(csv)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let table = parseCsv(text)
        let header = table.first ?? []
        let missing = requiredColumns.filter { !header.contains($0) }
        if !missing.isEmpty {
            throw OatcakeError("\(csv.lastPathComponent) doesn't look like a Granola export (no \(missing.joined(separator: ", ")) column).")
        }
        for cells in table.dropFirst() {
            rows.append(Dictionary(header.enumerated().map { ($1, $0 < cells.count ? cells[$0] : "") }, uniquingKeysWith: { a, _ in a }))
        }
    }
    guard !rows.isEmpty else { throw OatcakeError("There are no notes in that export.") }
    return rows
}

/// The ids under `key` (a bare id, or a link ending in one) of every meeting already in the Meetings folder.
func knownIds(_ root: URL, key: String) -> Set<String> {
    var ids = Set<String>()
    let idPattern = try! NSRegularExpression(pattern: "[0-9a-f-]{36}", options: .caseInsensitive)
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
        guard url.lastPathComponent == "meeting.json" else { continue }
        // An unreadable meeting.json can't be a duplicate.
        guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              let note = json[key] as? String, let match = firstMatch(idPattern, note)?[0] else { continue }
        ids.insert(match.lowercased())
    }
    return ids
}

/// A series folder's name. No leading dots: those make hidden folders (or "." and "..").
func seriesFolder(_ title: String) -> String {
    let name = safeName(title).replacingOccurrences(of: #"^\.+"#, with: "", options: .regularExpression).trimmed
    return name.isEmpty ? "Untitled" : name
}

/// Granola's transcript is one line per utterance, with no times or names: one paragraph each.
private func transcriptMarkdown(_ text: String) -> String {
    text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
}

/**
 * Writes an imported meeting into `base`: `files` maps a file name to its text, `moving` to a file
 * moved in. Two meetings with the same title in the same minute are different meetings: the second is
 * numbered. Written beside its final place, then renamed in, so a half-written meeting never shows.
 */
func writeImported(_ root: URL, base: String, title: String, startedAt: Date, files: [String: String], moving: [String: URL] = [:]) throws {
    let fm = FileManager.default
    let name = meetingFolderName(title: title, startedAt: startedAt)
    var rel = base + "/" + name
    var n = 2
    while fm.exists(try resolveInside(root, rel)) {
        rel = base + "/" + "\(name) (\(n))"
        n += 1
    }
    let dest = try resolveInside(root, rel)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString.prefix(8))")
    do {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        for (file, text) in files { try text.write(to: tmp.appendingPathComponent(file), atomically: false, encoding: .utf8) }
        for (file, source) in moving { try fm.moveItem(at: source, to: tmp.appendingPathComponent(file)) }
        try fm.moveItem(at: tmp, to: dest)
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
}

public func importGranola(_ file: URL, into root: URL, progress: ImportProgress = { _, _ in }) throws -> ImportResult {
    let rows = try readExport(file)
    progress(0, rows.count)
    var known = knownIds(root, key: "granolaNote")
    let titleOf = { (r: [String: String]) in (r["document_title"] ?? "").trimmed.isEmpty ? "Untitled" : (r["document_title"] ?? "").trimmed }
    var titles: [String: Int] = [:]
    for r in rows { titles[titleOf(r), default: 0] += 1 }

    var result = ImportResult()
    // Why the first note that couldn't be written couldn't be.
    var failure: Error?
    for (i, r) in rows.enumerated() {
        defer { progress(i + 1, rows.count) }
        let id = (r["document_id"] ?? "").trimmed.lowercased()
        guard id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil, let started = parseISO((r["document_created"] ?? "").trimmed) else {
            result.unreadable += 1
            continue
        }
        if known.contains(id) {
            result.skipped += 1
            continue
        }
        let title = titleOf(r)
        // Notes that share a title (a recurring meeting) get a folder of their own.
        let series = (titles[title] ?? 0) > 1 ? seriesFolder(title) : ""
        struct Meta: Encodable {
            var title: String
            var startedAt: String
            var source = "granola"
            var granolaNote: String
        }
        var files = ["summary.md": (r["summary"] ?? "").trimmed + "\n",
                     "transcript.md": transcriptMarkdown(r["transcript"] ?? ""),
                     "meeting.json": try encodeJSON(Meta(title: title, startedAt: isoString(started), granolaNote: noteURL + id)) + "\n"]
        if let notes = r["notes"]?.trimmed, !notes.isEmpty { files["notes.md"] = notes + "\n" }
        // One that can't be written (a title too long for a folder name, say) is counted and passed over.
        do {
            try writeImported(root, base: [granolaFolder, series].filter { !$0.isEmpty }.joined(separator: "/"),
                              title: title, startedAt: started, files: files)
        } catch {
            if failure == nil { failure = error }
            result.unreadable += 1
            continue
        }
        known.insert(id)
        result.imported += 1
    }
    // Nothing could be written at all: say why.
    if result.imported == 0, result.skipped == 0, let failure { throw failure }
    return result
}
