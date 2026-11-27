// Markdown as summaries, drafts for sharing and Ask's answers come in, read into blocks (headings,
// paragraphs, lists, quotes, code, tables and rules) with their inline emphasis and links, for
// SelectableMarkdown to draw. Transcript times like [12:34] become links that jump to that moment;
// links to meeting folders open the meeting. Raw HTML stays as text.

import Foundation
import OatcakeCore
import SwiftUI

/// A link that jumps to a transcript time.
let stampScheme = "oatcake-stamp"

struct MarkdownBlock {
    enum Kind {
        case heading(Int)
        case paragraph
        case listItem(marker: String, depth: Int)
        case quote
        case code
        case rule
        /// Rows of cells, the header row first when there is one.
        case table(rows: [[AttributedString]], hasHeader: Bool)
    }
    var kind: Kind
    var text: AttributedString
}

/// Turns [12:34] into a link to that moment (not inside an existing link's text).
func linkStamps(_ markdown: String) -> String {
    markdown.replacingOccurrences(of: #"\[(\d{1,2}:\d\d(?::\d\d)?)\](?!\()"#, with: "[$1](\(stampScheme):$1)", options: .regularExpression)
        // Two times side by side ("[01:02][01:22]") keep a space between them.
        .replacingOccurrences(of: #"(\(\#(stampScheme):[^)]*\))(?=\[)"#, with: "$1 ", options: .regularExpression)
}

func markdownBlocks(_ markdown: String) -> [MarkdownBlock] {
    let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: linkStamps(markdown), options: options, baseURL: nil) else {
        return [MarkdownBlock(kind: .paragraph, text: AttributedString(markdown))]
    }
    var blocks: [MarkdownBlock] = []
    var current: (id: Int, block: MarkdownBlock)?
    // The table being read: row (the header is row 0) → column → text. An empty cell has no run of its own.
    var table: (id: Int, cells: [Int: [Int: AttributedString]])?
    func endTable() {
        guard let cells = table?.cells else { return }
        let columns = (cells.values.flatMap(\.keys).max() ?? 0) + 1
        let rows = cells.keys.sorted().map { row in (0..<columns).map { cells[row]?[$0] ?? AttributedString() } }
        blocks.append(MarkdownBlock(kind: .table(rows: rows, hasHeader: cells[0] != nil), text: AttributedString()))
        table = nil
    }
    for run in parsed.runs {
        var piece = AttributedString(parsed[run.range])
        // Inline emphasis, code and links stay for Text to draw; the block structure is laid out here.
        piece.presentationIntent = nil
        let intent = run.presentationIntent
        if let cell = tableCell(intent) {
            if let open = current { blocks.append(open.block) }
            current = nil
            if table?.id != cell.table { endTable() }
            if table == nil { table = (cell.table, [:]) }
            table!.cells[cell.row, default: [:]][cell.column, default: AttributedString()] += piece
            continue
        }
        endTable()
        let id = intent?.components.first?.identity ?? -1
        if current?.id == id {
            current!.block.text += piece
            continue
        }
        if let current { blocks.append(current.block) }
        current = (id, MarkdownBlock(kind: kind(of: intent), text: piece))
    }
    if let current { blocks.append(current.block) }
    endTable()
    return blocks
}

/// Where a run sits in a table, if it's in one. The header is row 0, so body rows follow it whatever they count from.
private func tableCell(_ intent: PresentationIntent?) -> (table: Int, row: Int, column: Int)? {
    var table: Int?
    var row = 0, column = 0
    for component in intent?.components ?? [] {
        switch component.kind {
        case .table: table = component.identity
        case .tableHeaderRow: row = 0
        case .tableRow(let index): row = index + 1
        case .tableCell(let index): column = index
        default: break
        }
    }
    return table.map { ($0, row, column) }
}

private func kind(of intent: PresentationIntent?) -> MarkdownBlock.Kind {
    guard let intent else { return .paragraph }
    var kind: MarkdownBlock.Kind = .paragraph
    var depth = -1
    var ordinal: Int?
    var ordered: Bool?
    // Components run from the innermost (the paragraph itself) outwards.
    for component in intent.components {
        switch component.kind {
        case .header(let level): kind = .heading(level)
        case .codeBlock: kind = .code
        case .blockQuote: if case .paragraph = kind { kind = .quote }
        case .thematicBreak: kind = .rule
        case .listItem(let n): if ordinal == nil { ordinal = n }
        case .orderedList:
            depth += 1
            if ordered == nil { ordered = true }
        case .unorderedList:
            depth += 1
            if ordered == nil { ordered = false }
        default: break
        }
    }
    if let ordinal, depth >= 0 {
        return .listItem(marker: ordered == true ? "\(ordinal)." : depth % 2 == 0 ? "•" : "◦", depth: depth)
    }
    return kind
}

// MARK: - Links in meeting text

/// A link target that's a meeting folder (relative to the Meetings folder), or nil for anything else.
func meetingPath(from url: URL) -> String? {
    guard url.scheme == nil else { return nil }
    var rel = url.absoluteString.components(separatedBy: "#")[0]
    rel = rel.removingPercentEncoding ?? rel
    rel = rel.replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    if rel.range(of: #"\.(md|json)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
        rel = rel.split(separator: "/").dropLast().joined(separator: "/")
    }
    return rel.isEmpty ? nil : rel
}

/// The time a link to a meeting carries ("…#12:34"): where in its transcript to open it.
func meetingStamp(from url: URL) -> String? {
    guard let stamp = url.fragment, stamp.range(of: #"^\d{1,2}:\d\d(:\d\d)?$"#, options: .regularExpression) != nil else { return nil }
    return stamp
}

/**
 * Ask's answers come from a model that has read whatever was said on your calls, so a web link in
 * one is shown as plain text rather than made clickable. Links to meetings open in Oatcake. One the
 * model wrote itself reads "Leads sync · Oct 29", like dates elsewhere, whatever its text was; the
 * ones Oatcake made from the model's citations (they carry a time) keep theirs.
 */
func answerMarkdown(_ markdown: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"\[((?:[^\]\\]|\\.)*)\]\(([^)\s]*)\)"#)
    var out = markdown
    for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
        guard let whole = Range(match.range, in: markdown), let textRange = Range(match.range(at: 1), in: markdown),
              let hrefRange = Range(match.range(at: 2), in: markdown) else { continue }
        let text = String(markdown[textRange]), href = String(markdown[hrefRange])
        let replacement: String
        if href.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            replacement = text == href ? text : "\(text) (\(href))"
        } else if let url = URL(string: href), meetingStamp(from: url) == nil, let rel = meetingPath(from: url), let label = meetingLinkText(rel) {
            replacement = "[\(label)](\(href))"
        } else {
            continue
        }
        out.replaceSubrange(Range(NSRange(whole, in: markdown), in: out)!, with: replacement)
    }
    return out
}
