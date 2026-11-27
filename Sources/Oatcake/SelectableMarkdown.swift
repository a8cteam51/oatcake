// Markdown drawn as one piece of text, so a selection can run from any point in it to any other and
// be copied whole: a summary, a draft for sharing or an answer in Ask. When each block was a view of
// its own, a selection stopped at the end of a paragraph or list item: macOS only lets you select
// inside one view at a time. VoiceOver finds the headings with its rotor.

import AppKit
import SwiftUI

struct SelectableMarkdown: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 13
    /// Words being looked for (Find, or the search a meeting was opened from), marked where they are.
    var marks: [String] = []
    /// What VoiceOver calls the text.
    var label = "Answer"
    /// Escape, while the text has the keyboard. Nil: it goes where it would have gone (Find's Done).
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, laid out on demand: the height for a given width is asked for before it's drawn.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Its width is set by AnswerTextView, which lays the text blocks out again when it changes.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = AnswerTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = context.environment.openURL
        (view as? AnswerTextView)?.onEscape = onEscape
        view.setAccessibilityLabel(label)
        let shown = Coordinator.Shown(markdown: markdown, size: fontSize, marks: marks)
        guard context.coordinator.shown != shown else { return }
        context.coordinator.shown = shown
        view.textStorage?.setAttributedString(markdownText(markdown, fontSize: fontSize, marks: marks))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let view = nsView as? AnswerTextView else { return nil }
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 560
        return CGSize(width: width, height: view.height(at: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// What the text was last made from, so it's only made again when that changes.
        struct Shown: Equatable {
            let markdown: String
            let size: CGFloat
            let marks: [String]
        }
        var shown: Shown?
        var open: OpenURLAction?

        /// Links go the way the rest of the window's do: to a meeting, or nowhere.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { open?(url) }
            return true
        }
    }
}

extension NSAttributedString.Key {
    /// A heading's level, on its text, for VoiceOver's headings rotor.
    static let markdownHeading = NSAttributedString.Key("OatcakeMarkdownHeading")
}

private final class AnswerTextView: NSTextView, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    var onEscape: (() -> Void)?

    /// VoiceOver's Headings rotor (and VO-⌘-H) goes from heading to heading in the text, as it would
    /// on a web page. Without it the text is one text area with nothing to move by but lines.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)]
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let storage = textStorage else { return nil }
        var headings: [NSRange] = []
        storage.enumerateAttribute(.markdownHeading, in: NSRange(location: 0, length: storage.length)) { level, range, _ in
            if level != nil { headings.append(range) }
        }
        let forward = search.searchDirection == .next
        let from = search.currentItem?.targetRange.location ?? (forward ? -1 : Int.max)
        guard let found = forward ? headings.first(where: { $0.location > from }) : headings.last(where: { $0.location < from }) else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = found
        result.customLabel = storage.attributedSubstring(from: found).string
        return result
    }

    /**
     * The text's height at a width. SwiftUI also asks about widths it won't use (its ideal size, with
     * no width given), so the text is laid out at the view's own width again afterwards: left at the
     * width asked about, the lines kept it until the view next changed size.
     */
    func height(at width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        lay(out: width)
        let height = ceil(layout.usedRect(for: container).height)
        if frame.width > 0, frame.width != width { lay(out: frame.width) }
        return height
    }

    /// Laid out at a width. Text blocks (a quote's bar, a code block, a table) keep the width they
    /// were first laid out at when only the container's width changes, so the whole text goes again.
    private func lay(out width: CGFloat) {
        guard let container = textContainer, let layout = layoutManager, let storage = textStorage else { return }
        if container.containerSize.width != width {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        lay(out: newSize.width)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    /// What's copied or dragged out keeps its bold, italics and lists, and leaves behind what only
    /// means something here: links to meetings and to times in a transcript, which would paste as
    /// links to nowhere, and this window's text colour (white, when it's copied from a dark window).
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, selectedRange().length > 0 else { return super.writeSelection(to: pboard, types: types) }
        let copy = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selectedRange()))
        let whole = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(.foregroundColor, range: whole)
        // Find's marks and the tint behind a time are this window's too.
        copy.removeAttribute(.backgroundColor, range: whole)
        copy.enumerateAttribute(.link, in: whole) { value, range, _ in
            let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
            if !["http", "https"].contains(url?.scheme?.lowercased() ?? "") { copy.removeAttribute(.link, range: range) }
        }
        pboard.clearContents()
        return pboard.writeObjects([copy])
    }

    /// One answer's selection goes when you click into another's (or anywhere else).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }
}

/// Markdown as text for a text view: each block as one or more paragraphs, spaced as they were when
/// each was a view of its own. Tables, quotes, code and rules are text blocks (TextKit 1 draws them), so they
/// keep their borders, bar and tint and can still be selected through.
func markdownText(_ markdown: String, fontSize: CGFloat, marks: [String] = []) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let blocks = markdownBlocks(markdown)
    let body = NSFont.systemFont(ofSize: fontSize)

    func paragraph(_ change: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.3
        change(style)
        return style
    }
    /// A paragraph break before what comes next, unless a text block's last paragraph ended with one.
    func newParagraph() {
        if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n")) }
    }
    /// A block goes in as one or more paragraphs; the space above it belongs to the first of them.
    func add(_ text: NSAttributedString, _ style: NSMutableParagraphStyle, above: CGFloat) {
        let block = NSMutableAttributedString(attributedString: text)
        block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
        if above > 0, out.length > 0 {
            let first = (block.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            let spaced = style.mutableCopy() as! NSMutableParagraphStyle
            spaced.paragraphSpacingBefore = above
            block.addAttribute(.paragraphStyle, value: spaced, range: first)
        }
        newParagraph()
        out.append(block)
    }
    /// Room above a tinted box, given to what comes before it: the tint would fill a margin of its own.
    func spaceBefore(_ above: CGFloat) {
        guard out.length > 0 else { return }
        let last = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let style = (out.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle else { return }
        switch style.textBlocks.last {
        case let cell as NSTextTableBlock: cell.table.setWidth(above, type: .absoluteValueType, for: .margin, edge: .maxY)
        case let box? where box.backgroundColor == nil: box.setWidth(above, type: .absoluteValueType, for: .margin, edge: .maxY)
        default:
            style.paragraphSpacing = above
            out.addAttribute(.paragraphStyle, value: style, range: last)
        }
    }
    /// Paragraphs in a box of their own (a quote, code, a rule's line), the space above as its margin.
    func add(_ text: NSAttributedString, in box: NSTextBlock, _ style: NSMutableParagraphStyle, above: CGFloat) {
        if box.backgroundColor != nil { spaceBefore(above) }
        else if out.length > 0 { box.setWidth(above, type: .absoluteValueType, for: .margin, edge: .minY) }
        box.setContentWidth(100, type: .percentageValueType)
        style.textBlocks = [box]
        let block = NSMutableAttributedString(attributedString: text)
        block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
        newParagraph()
        out.append(block)
        // Ended here, so what follows isn't drawn inside the box.
        out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style]))
    }

    for (index, block) in blocks.enumerated() {
        var above: CGFloat = 10
        if case .heading = block.kind { above = 18 }
        if index > 0, case .listItem = block.kind, case .listItem = blocks[index - 1].kind { above = 3 }

        switch block.kind {
        case .heading(let level):
            let heading = NSMutableAttributedString(attributedString: inlineText(block.text, font: .systemFont(ofSize: level <= 2 ? fontSize + 2 : fontSize + 1, weight: .semibold)))
            heading.addAttribute(.markdownHeading, value: level, range: NSRange(location: 0, length: heading.length))
            add(heading, paragraph(), above: above)
        case .paragraph:
            add(inlineText(block.text, font: body), paragraph(), above: above)
        case .listItem(let marker, let depth):
            let start = CGFloat(depth) * 18, text = start + (marker.count > 1 ? 24 : 14)
            let item = NSMutableAttributedString(string: marker + "\t", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
            item.append(inlineText(block.text, font: body))
            add(item, paragraph {
                $0.firstLineHeadIndent = start
                $0.headIndent = text
                $0.tabStops = [NSTextTab(textAlignment: .left, location: text)]
            }, above: above)
        case .quote:
            // A bar down its left side.
            let box = NSTextBlock()
            box.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            box.setBorderColor(.separatorColor, for: .minX)
            box.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minX)
            add(inlineText(block.text, font: body, color: .secondaryLabelColor), in: box, paragraph(), above: above)
        case .code:
            let code = String(block.text.characters).trimmingCharacters(in: .newlines)
            let box = NSTextBlock()
            box.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white.withAlphaComponent(0.06) : .black.withAlphaComponent(0.06) }
            box.setWidth(10, type: .absoluteValueType, for: .padding)
            add(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                                              .foregroundColor: NSColor.labelColor]),
                in: box, paragraph { $0.lineSpacing = 2 }, above: above)
        case .rule:
            let box = NSTextBlock()
            box.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            box.setBorderColor(.separatorColor, for: .maxY)
            add(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)]), in: box,
                paragraph { $0.lineSpacing = 0 }, above: above)
        case .table(let rows, let hasHeader):
            // As wide as its content, with a line round it and between its rows.
            let columns = rows.map(\.count).max() ?? 0
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setWidth(1, type: .absoluteValueType, for: .border)
            table.setBorderColor(.separatorColor)
            if out.length > 0 { table.setWidth(above, type: .absoluteValueType, for: .margin, edge: .minY) }
            let small = NSFont.systemFont(ofSize: fontSize - 1)
            let header = NSFont.systemFont(ofSize: fontSize - 1, weight: .semibold)
            let cells = rows.enumerated().map { r, row in
                (0..<columns).map { c in inlineText(row.indices.contains(c) ? row[c] : AttributedString(), font: hasHeader && r == 0 ? header : small) }
            }
            // Each column as wide as its widest cell, so the table takes no more room than it needs.
            let widths = (0..<columns).map { c in (cells.map { ceil($0[c].size().width) }.max() ?? 0) }
            newParagraph()
            for (r, row) in cells.enumerated() {
                for (c, cell) in row.enumerated() {
                    let box = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    if r > 0 {
                        box.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                        box.setBorderColor(.separatorColor, for: .minY)
                    }
                    box.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                    box.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                    box.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                    box.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                    box.setContentWidth(widths[c] + 1, type: .absoluteValueType)
                    let style = paragraph { $0.lineSpacing = 0 }
                    style.textBlocks = [box]
                    let text = NSMutableAttributedString(attributedString: cell)
                    text.append(NSAttributedString(string: "\n", attributes: [.font: small]))
                    text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                    out.append(text)
                }
            }
        }
    }
    // A text block's closing paragraph break isn't a line of its own at the end.
    if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    mark(marks, in: out)
    return out
}

/// Find's words marked where they are, as `markingFound` marks them in a SwiftUI Text.
private func mark(_ words: [String], in text: NSMutableAttributedString) {
    let string = text.string as NSString
    for word in words where !word.isEmpty {
        var from = 0
        while from < string.length {
            let found = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound, found.length > 0 else { break }
            text.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: found)
            from = NSMaxRange(found)
        }
    }
}

/// A block's text with its bold, italics, code and links, in AppKit's terms.
private func inlineText(_ text: AttributedString, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for run in text.runs {
        var runFont = font
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) {
            runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
        } else {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)), size: font.pointSize) ?? font }
        }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link {
            attributes[.link] = link
            // A link to a moment in a transcript looks like the time chips elsewhere: tinted behind, digits even.
            // Only Oatcake's own links: a web page's #section isn't a moment.
            if link.fragment?.isEmpty == false, !["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.12)
                runFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .medium)
            }
        }
        attributes[.font] = runFont
        out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return out
}
