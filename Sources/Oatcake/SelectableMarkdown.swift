// Markdown drawn as one piece of text, so a selection can run from any point in it to any other and
// be copied whole. MarkdownView lays each block out as its own view, and macOS only lets you select
// inside one of those at a time, which is no good for an answer you want to paste somewhere else.

import AppKit
import SwiftUI

struct SelectableMarkdown: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 13
    /// Escape, while the text has the keyboard.
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, laid out on demand: the height for a given width is asked for before it's drawn.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        view.setAccessibilityLabel("Answer")
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = context.environment.openURL
        (view as? AnswerTextView)?.onEscape = onEscape
        guard context.coordinator.shown != markdown || context.coordinator.size != fontSize else { return }
        context.coordinator.shown = markdown
        context.coordinator.size = fontSize
        view.textStorage?.setAttributedString(markdownText(markdown, fontSize: fontSize))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 560
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown: String?
        var size: CGFloat = 0
        var open: OpenURLAction?

        /// Links go the way the rest of the window's do: to a meeting, or nowhere.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { open?(url) }
            return true
        }
    }
}

private final class AnswerTextView: NSTextView {
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEscape() }

    /// One answer's selection goes when you click into another's (or anywhere else).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }
}

/// Markdown as text for a text view: the blocks MarkdownView draws, as paragraphs with the same
/// sizes and spacing. A table's columns are lined up with tab stops.
func markdownText(_ markdown: String, fontSize: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let blocks = markdownBlocks(markdown)
    let body = NSFont.systemFont(ofSize: fontSize)

    func paragraph(_ change: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.3
        change(style)
        return style
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
        if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
        out.append(block)
    }

    for (index, block) in blocks.enumerated() {
        var above: CGFloat = 10
        if case .heading = block.kind { above = 18 }
        if index > 0, case .listItem = block.kind, case .listItem = blocks[index - 1].kind { above = 3 }

        switch block.kind {
        case .heading(let level):
            add(inlineText(block.text, font: .systemFont(ofSize: level <= 2 ? fontSize + 2 : fontSize + 1, weight: .semibold)), paragraph(), above: above)
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
            add(inlineText(block.text, font: body, color: .secondaryLabelColor), paragraph {
                $0.firstLineHeadIndent = 12
                $0.headIndent = 12
            }, above: above)
        case .code:
            let code = String(block.text.characters).trimmingCharacters(in: .newlines)
            // No tinted box as MarkdownView has: a background here would only sit behind the letters.
            add(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                                              .foregroundColor: NSColor.labelColor]),
                paragraph {
                    $0.lineSpacing = 2
                    $0.firstLineHeadIndent = 12
                    $0.headIndent = 12
                }, above: above)
        case .rule:
            add(NSAttributedString(string: "———", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]), paragraph(), above: above)
        case .table(let rows, let hasHeader):
            let small = NSFont.systemFont(ofSize: fontSize - 1)
            let cells = rows.enumerated().map { r, row in
                row.map { inlineText($0, font: hasHeader && r == 0 ? .systemFont(ofSize: fontSize - 1, weight: .semibold) : small) }
            }
            // Each column starts where the widest cell before it ends, plus a gap.
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for column in 0..<max(0, (rows.map(\.count).max() ?? 0) - 1) {
                x += (cells.compactMap { $0.indices.contains(column) ? ceil($0[column].size().width) : nil }.max() ?? 0) + 18
                stops.append(NSTextTab(textAlignment: .left, location: x))
            }
            let table = NSMutableAttributedString()
            for (r, row) in cells.enumerated() {
                if r > 0 { table.append(NSAttributedString(string: "\n")) }
                for (c, cell) in row.enumerated() {
                    if c > 0 { table.append(NSAttributedString(string: "\t", attributes: [.font: small])) }
                    table.append(cell)
                }
            }
            add(table, paragraph {
                $0.lineSpacing = 3
                $0.tabStops = stops
                $0.lineBreakMode = .byClipping
            }, above: above)
        }
    }
    return out
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
        if let link = run.link { attributes[.link] = link }
        attributes[.font] = runFont
        out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return out
}
