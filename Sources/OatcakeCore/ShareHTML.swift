import Foundation

// Markdown as HTML, for the pages a shared folder is published as. Everything from a meeting is
// text that came out of a call or a model, so all of it is escaped: no HTML in the Markdown is
// passed through, and only web links are made into links.

public func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Headings, paragraphs, lists (nested), quotes, code, tables and rules, with bold, italics, code,
/// strike-through and web links inside them.
public func markdownHTML(_ markdown: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: markdown, options: options, baseURL: nil) else {
        return "<p>\(escapeHTML(markdown))</p>"
    }

    /// One block: the innermost thing with an identity (a paragraph, a heading, a table cell).
    struct Block {
        var id: Int
        var html = ""
        var kind: PresentationIntent.Kind = .paragraph
        /// Lists it sits in, outermost first: each one's identity and whether it's numbered.
        var lists: [(id: Int, ordered: Bool)] = []
        /// The list item it belongs to (the innermost), so two paragraphs of one item share an <li>.
        var item: Int?
        var quoted = false
        var table: (id: Int, row: Int, column: Int)?
    }
    var blocks: [Block] = []
    for run in parsed.runs {
        let components = run.presentationIntent?.components ?? []
        let id = components.first?.identity ?? -1
        if blocks.last?.id != id {
            var block = Block(id: id)
            var row = 0, column = 0, table: Int?
            // Components run from the innermost outwards.
            for component in components {
                switch component.kind {
                case .header, .codeBlock, .thematicBreak: block.kind = component.kind
                case .blockQuote: block.quoted = true
                case .listItem: if block.item == nil { block.item = component.identity }
                case .orderedList: block.lists.insert((component.identity, true), at: 0)
                case .unorderedList: block.lists.insert((component.identity, false), at: 0)
                case .table: table = component.identity
                case .tableHeaderRow: row = 0
                case .tableRow(let index): row = index + 1
                case .tableCell(let index): column = index
                default: break
                }
            }
            if let table { block.table = (table, row, column) }
            blocks.append(block)
        }
        var isCode = false
        if case .codeBlock = blocks[blocks.count - 1].kind { isCode = true }
        blocks[blocks.count - 1].html += inlineHTML(parsed[run.range], code: isCode)
    }

    var out = ""
    var open: [(id: Int, ordered: Bool, item: Int?)] = []   // lists open now, outermost first
    var table: Int?
    var tableRow = -1
    func closeItem() { if let last = open.last, last.item != nil { out += "</li>"; open[open.count - 1].item = nil } }
    func closeLists(to depth: Int) {
        while open.count > depth {
            closeItem()
            out += open.last!.ordered ? "</ol>" : "</ul>"
            open.removeLast()
        }
    }
    func closeTable() {
        guard table != nil else { return }
        out += "</tr></table>"
        table = nil
        tableRow = -1
    }
    for block in blocks {
        if let cell = block.table {
            closeLists(to: 0)
            if table != cell.id { closeTable(); out += "<table>"; table = cell.id }
            if tableRow != cell.row { out += tableRow >= 0 ? "</tr><tr>" : "<tr>"; tableRow = cell.row }
            out += cell.row == 0 ? "<th>\(block.html)</th>" : "<td>\(block.html)</td>"
            continue
        }
        closeTable()
        // Lists: keep those this block is still inside, close the rest, open what's new.
        var shared = 0
        while shared < open.count, shared < block.lists.count, open[shared].id == block.lists[shared].id { shared += 1 }
        closeLists(to: shared)
        for list in block.lists[shared...] {
            out += list.ordered ? "<ol>" : "<ul>"
            open.append((list.id, list.ordered, nil))
        }
        if !open.isEmpty, open.last!.item != block.item {
            closeItem()
            out += "<li>"
            open[open.count - 1].item = block.item
        }
        let body: String
        switch block.kind {
        case .header(let level): body = "<h\(min(max(level + 1, 2), 4))>\(block.html)</h\(min(max(level + 1, 2), 4))>"
        case .codeBlock: body = "<pre><code>\(block.html.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression))</code></pre>"
        case .thematicBreak: body = "<hr>"
        default: body = open.isEmpty ? "<p>\(block.html)</p>" : block.html
        }
        out += block.quoted ? "<blockquote>\(body)</blockquote>" : body
    }
    closeLists(to: 0)
    closeTable()
    return out
}

/// A stretch of text with its emphasis. A link is kept only when it goes to a web address.
private func inlineHTML(_ text: AttributedSubstring, code: Bool) -> String {
    var out = ""
    for run in text.runs {
        var piece = escapeHTML(String(text[run.range].characters))
        if code { out += piece; continue }
        piece = piece.replacingOccurrences(of: "\n", with: "<br>")
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) { piece = "<code>\(piece)</code>" }
        if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
        if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
        if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
        if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            piece = "<a href=\"\(escapeHTML(link.absoluteString))\" rel=\"noopener noreferrer\">\(piece)</a>"
        }
        out += piece
    }
    return out
}
