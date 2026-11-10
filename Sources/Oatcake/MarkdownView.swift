// Renders the Markdown that summaries and Ask answers come in: headings, paragraphs, lists, quotes,
// code, tables and rules, with inline emphasis and links. Transcript times like [12:34] become links that
// jump to that moment; links to meeting folders open the meeting. Raw HTML stays as text.

import Foundation
import SwiftUI

/// A link that jumps to a transcript time.
let stampScheme = "oatcake-stamp"

struct MarkdownView: View {
    let markdown: String
    var fontSize: CGFloat = 14

    var body: some View {
        let blocks = markdownBlocks(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : topSpacing(block, previous: blocks[index - 1]))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topSpacing(_ block: MarkdownBlock, previous: MarkdownBlock) -> CGFloat {
        if case .heading = block.kind { return 18 }
        if case .listItem = block.kind, case .listItem = previous.kind { return 3 }
        return 10
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(.system(size: level <= 2 ? fontSize + 2 : fontSize + 1, weight: .semibold))
        case .paragraph:
            Text(block.text).font(.system(size: fontSize)).lineSpacing(fontSize * 0.3)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: fontSize).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(block.text).font(.system(size: fontSize)).lineSpacing(fontSize * 0.3)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote:
            Text(block.text).font(.system(size: fontSize)).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.line).frame(width: 3) }
        case .code:
            Text(block.text).font(.system(size: fontSize - 1, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.fill))
        case .rule:
            Divider()
        case .table(let rows, let hasHeader):
            // As wide as its content, like the bordered tables the Electron version drew.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.system(size: fontSize - 1, weight: hasHeader && index == 0 ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.line) }
        }
    }
}

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

/**
 * Ask's answers come from a model that has read whatever was said on your calls, so a web link in
 * one is shown as plain text rather than made clickable. Links to meetings open in Oatcake and read
 * "Leads sync · Oct 29", like dates elsewhere, whatever the model wrote.
 */
func answerMarkdown(_ markdown: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)\s]*)\)"#)
    var out = markdown
    for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
        guard let whole = Range(match.range, in: markdown), let textRange = Range(match.range(at: 1), in: markdown),
              let hrefRange = Range(match.range(at: 2), in: markdown) else { continue }
        let text = String(markdown[textRange]), href = String(markdown[hrefRange])
        let replacement: String
        if href.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            replacement = text == href ? text : "\(text) (\(href))"
        } else if let url = URL(string: href), let rel = meetingPath(from: url), let label = meetingLinkText(rel) {
            replacement = "[\(label)](\(href))"
        } else {
            continue
        }
        out.replaceSubrange(Range(NSRange(whole, in: markdown), in: out)!, with: replacement)
    }
    return out
}

/// "Team 51 – Leads sync · Oct 29" for the folder "…/2026-10-29 1630 Team 51 – Leads sync".
private func meetingLinkText(_ rel: String) -> String? {
    let name = rel.split(separator: "/").last.map(String.init) ?? rel
    let regex = try! NSRegularExpression(pattern: #"^\d{4}-(\d\d)-(\d\d)(?: \d{4})? (.+)$"#)
    guard let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
          let month = Range(m.range(at: 1), in: name).flatMap({ Int(name[$0]) }),
          let day = Range(m.range(at: 2), in: name).flatMap({ Int(name[$0]) }),
          let title = Range(m.range(at: 3), in: name).map({ String(name[$0]) }), (1...12).contains(month) else { return nil }
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return "\(title.replacingOccurrences(of: "]", with: "\\]")) · \(months[month - 1]) \(day)"
}
