import OatcakeCore
import SwiftUI

/// Search's words, what they last found and the result chosen, kept in the model while search is
/// closed: opening it again after opening a result brings them back, to try the next one.
struct SearchState {
    var query = ""
    /// What the last look through every meeting's text found, and the words it was for.
    var found: (query: String, hits: [SearchHit])?
    /// The result Return opens, by its path: the first when nil.
    var chosen: String?
}

/// Search, over the window (⌥⌘F, or the button over the meeting list): the meetings with every word
/// typed in their title, folder, summary, to-dos, notes or transcript, newest first, as you type.
/// ↑ and ↓ choose one, Return or a click opens it where the words are, and Escape or a click
/// outside closes it.
struct SearchOverlay: View {
    @Environment(AppModel.self) private var model
    /// The results shown, and what each was found by, worked out when the words or what they found
    /// change rather than each time the panel is drawn.
    @ViewState private var rows: [TreeNode] = []
    @ViewState private var hits: [String: SearchHit] = [:]
    /// Where the pointer was last seen: only a pointer that moves picks a result.
    @ViewState private var pointer = NSEvent.mouseLocation
    @ViewState private var listHeight: CGFloat = 0

    /// How dark the window behind search goes.
    static let dimming = 0.5

    private var root: TreeNode? { model.library.tree }
    private var search: String { model.search.query.trimmed }
    /// Every meeting's text has been looked through for these words.
    private var done: Bool { model.search.found?.query == search }
    /// Where the chosen result is in the list: the first, unless another is chosen and still there.
    private var chosen: Int { rows.firstIndex { $0.path == model.search.chosen } ?? 0 }

    var body: some View {
        ZStack(alignment: .top) {
            // Dark enough that what's behind reads as behind, in a dark window too; a click on it
            // closes search. The toolbar is dimmed the same, by ToolbarDim.
            Color.black.opacity(Self.dimming)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
                .background(ToolbarDim(opacity: Self.dimming) { close() })
            VStack(spacing: 0) {
                field
                if !search.isEmpty {
                    Divider()
                    if !rows.isEmpty {
                        list
                    } else if done {
                        Text("No meetings match “\(search)”.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
            .frame(width: 600)
            // Solid: a material took on the dimming behind it and went grey, in light windows most.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .padding(.top, 60)
        }
        .onExitCommand { close() }
        .onChange(of: search) { model.search.chosen = nil }
        .onChange(of: search, initial: true) { showResults() }
        // Searched again when the words change, and when a meeting does.
        .task(id: "\(model.library.diskVersion) \(search)") { await searchText(search) }
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
            KeyedTextField(text: $model.search.query, placeholder: "Search meetings",
                           font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize),
                           onMove: move,
                           onReturn: { if rows.indices.contains(chosen) { open(rows[chosen]) } },
                           onEscape: { close() })
                .accessibilityLabel("Search meetings")
            if !search.isEmpty {
                // Until every meeting's text has been looked through, the results are those found by title or folder.
                Text(done ? "\(rows.count) meeting\(rows.count == 1 ? "" : "s")" : "Searching…")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if !model.search.query.isEmpty {
                Button { model.search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Clear the search").accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// As tall as the results, up to 420 points, then scrolling.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let words = searchWords(search)
                    let chosen = chosen
                    ForEach(Array(rows.enumerated()), id: \.element.path) { i, m in
                        Button { open(m) } label: { row(m, hit: hits[m.path], words: words, chosen: i == chosen) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(i == chosen ? .isSelected : [])
                            .id(m.path)
                            .onContinuousHover { phase in
                                // A list scrolled by ↑ and ↓ moves rows under a pointer at rest: that doesn't pick one.
                                guard case .active = phase, NSEvent.mouseLocation != pointer else { return }
                                pointer = NSEvent.mouseLocation
                                model.search.chosen = m.path
                            }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 420))
            .onChange(of: model.search.chosen) { if let path = model.search.chosen { proxy.scrollTo(path) } }
            .onAppear { if let path = model.search.chosen { proxy.scrollTo(path) } }
        }
    }

    private func row(_ m: TreeNode, hit: SearchHit?, words: [String], chosen: Bool) -> some View {
        let parent = parentOf(m.path)
        let secondary = chosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(markingFound(meetingTitle(m), words)).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                if let date = meetingDate(m) { Text(compactDate(date)).foregroundStyle(secondary).monospacedDigit() }
            }
            if !parent.isEmpty { Text(markingFound(folderPath(parent), words)).font(.callout).foregroundStyle(secondary).lineLimit(1) }
            if let hit, let file = hit.file, !hit.line.isEmpty {
                // Found in the meeting's text: the line that has the words, and where it is.
                let place = [MeetingFile.summary: "Summary", .todo: "To-dos", .notes: "My notes", .transcript: "Transcript"][file] ?? ""
                (Text("\(place) · ").fontWeight(.medium) + Text(markingFound(hit.line, words)))
                    .font(.callout).foregroundStyle(secondary).lineLimit(2)
            }
        }
        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    /// ↑ or ↓: the result before or after the one chosen.
    private func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        model.search.chosen = rows[min(max(chosen + by, 0), rows.count - 1)].path
    }

    /// What a meeting is found by, besides its text.
    private func label(_ m: TreeNode) -> String { "\(meetingTitle(m)) \(folderPath(parentOf(m.path)))" }

    /// The results for the words: what every meeting's text was found to have, once it's been looked
    /// through (a moment after you stop typing), and until then the meetings with the words in their
    /// title or folder.
    private func showResults() {
        if let found = model.search.found, found.query == search {
            rows = found.hits.compactMap { root?.find($0.path) }
            hits = Dictionary(found.hits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            rows = search.isEmpty ? [] : listedIn(root).filter { hasEveryWord(of: search, in: label($0)) }
            hits = [:]
        }
    }

    /// Looks through every meeting's text, off the main thread. Each file is read once and kept until
    /// it changes. Words typed since, or search closing, stop a look that's under way.
    private func searchText(_ search: String) async {
        guard !search.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let all = listedIn(root).map { (path: $0.path, label: label($0)) }
        let meetings = model.library.meetings, todos = model.config.todosEnabled
        let looking = Task.detached { meetings.search(search, in: all, todos: todos) }
        let hits = await withTaskCancellationHandler { await looking.value } onCancel: { looking.cancel() }
        guard !Task.isCancelled else { return }
        model.search.found = (search, hits)
        showResults()
    }

    /// Opens a meeting, in the list of its folder. One found by its text opens where the words are,
    /// with them in Find and marked, as Mail marks a search's words in a message it opens. Search
    /// keeps its words and results, and this one chosen, for when it's opened again.
    private func open(_ m: TreeNode) {
        model.search.chosen = m.path
        close()
        guard let file = hits[m.path]?.file else { return model.openMeeting(m.path) }
        let tab: MeetingTab = file == .transcript ? .transcript : file == .notes ? .notes : .summary
        // Find gets the words found in the text, not those that were only in the title or folder:
        // it looks for lines with all of them, and wouldn't find one.
        let words = searchWords(search)
        let inText = words.filter { !hasEveryWord(of: $0, in: label(m)) }
        model.openMeeting(m.path, jump: Jump(tab: tab, stamp: hits[m.path]?.stamp, words: inText.isEmpty ? words : inText))
    }

    private func close() { model.searching = false }
}

/**
 * The window's toolbar, dimmed as the rest of the window is while search is open: the toolbar is
 * drawn above the window's content, where nothing in SwiftUI reaches, and left bright it was the
 * brightest thing in the window. A click on it closes search, as a click on the rest does.
 */
private struct ToolbarDim: NSViewRepresentable {
    let opacity: Double
    let onClick: () -> Void

    func makeNSView(context: Context) -> Anchor { Anchor(dim: Dim(opacity: opacity, onClick: onClick)) }
    func updateNSView(_ view: Anchor, context: Context) { view.dim.onClick = onClick }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.dim.removeFromSuperview() }

    /// Puts the dimming over the toolbar of whichever window it's in.
    final class Anchor: NSView {
        let dim: Dim
        init(dim: Dim) {
            self.dim = dim
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        private var watching: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (search closed) stops the watching, as well as moving to another.
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            // The window's frame view holds both the content and the toolbar above it.
            guard let window, let frame = window.contentView?.superview else { return dim.removeFromSuperview() }
            frame.addSubview(dim, positioned: .above, relativeTo: nil)
            place()
            // The toolbar's height changes in full screen, where it leaves the window.
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
        }

        private func place() {
            guard let window, let frame = dim.superview else { return }
            let toolbar = window.frame.height - window.contentLayoutRect.maxY
            dim.frame = NSRect(x: 0, y: frame.bounds.height - toolbar, width: frame.bounds.width, height: toolbar)
        }
    }

    final class Dim: NSView {
        let opacity: Double
        var onClick: () -> Void
        init(opacity: Double, onClick: @escaping () -> Void) {
            self.opacity = opacity
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor }
        override func mouseDown(with event: NSEvent) { onClick() }

        /// The window's close, minimise and zoom buttons still take their clicks, dimmed or not.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let buttons = window?.standardWindowButton(.closeButton)?.superview, let superview,
               buttons.convert(buttons.bounds, to: superview).contains(point) { return nil }
            return super.hitTest(point)
        }
    }
}
