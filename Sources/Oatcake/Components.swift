// Small shared pieces of the design: avatars, chips, notices, the recording dot, checkboxes, meters.

import OatcakeCore
import SwiftUI

extension Color {
    static let amber = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.63, green: 0.28, blue: 0, alpha: 1) })
    static let fill = Color.primary.opacity(0.06)
    /// The edge of a field to type in, a card or the Ask bar: at least 3:1 against the window, light
    /// (white to #ececec) or dark (#1e1e1e to #323232), and more with Increase Contrast.
    static let line = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4)
        case .accessibilityHighContrastDarkAqua: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6)
        case .accessibilityHighContrastAqua: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65)
        default: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
        }
    })
}

/// A visible hint for an existing shortcut; the menu or control still owns the key binding.
struct ShortcutHint: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(verbatim: keys)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

struct ColourSwatchPopover: View {
    let title: String
    let selected: SwatchColour?
    let choose: (SwatchColour) -> Void
    var reset: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ColourSwatches(selected: selected, choose: choose)
            if let reset {
                Button("Use the colour Oatcake gave them", action: reset).buttonStyle(.link)
            }
        }
        .padding(16)
    }
}

private struct ColourSwatches: View {
    let selected: SwatchColour?
    let choose: (SwatchColour) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), spacing: 8) {
            ForEach(SwatchColour.allCases, id: \.self) { colour in
                Button { choose(colour) } label: {
                    Circle().fill(colour.swatch).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3).opacity(selected == colour ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(colour.title)
                .accessibilityLabel(colour.title)
                .accessibilityAddTraits(selected == colour ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    var remember = true
    var color: Color?
    /// Read so a colour chosen in Settings shows straight away.
    @AppStorage(colorsChangedKey) private var colorsChanged = 0

    var body: some View {
        let _ = colorsChanged
        let p = person(name, remember: false)
        Text(p.initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color ?? p.color))
            // Their colour is claimed once the avatar is on screen, not while it's being drawn.
            .task(id: name) { if remember { rememberColor(name) } }
            // Always beside the name it stands for: read out, its initials would come before it.
            .accessibilityHidden(true)
    }
}

/// A time like 12:34 in a small rounded box; tappable when it jumps somewhere.
struct Chip: View {
    enum Style { case normal, prep, outline, pending }
    let text: String
    var style = Style.normal
    var help = "Jump to this moment in the transcript"
    var action: (() -> Void)?
    @AppStorage(TextScale.key) private var textScale = 1.0
    @Environment(\.colorSchemeContrast) private var contrast

    /// The accent as text on its own light tint. The accent alone is under 4.5:1 there, light and
    /// dark, so it's taken towards black or white: far enough for each of macOS's accent colours
    /// (yellow in light, purple in dark need the most) on a window from #ececec to #323232.
    private static let tintText = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor
        return switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: accent.blended(withFraction: 0.4, of: .white) ?? accent
        case .accessibilityHighContrastDarkAqua: accent.blended(withFraction: 0.55, of: .white) ?? accent
        case .accessibilityHighContrastAqua: accent.blended(withFraction: 0.65, of: .black) ?? accent
        default: accent.blended(withFraction: 0.5, of: .black) ?? accent
        }
    })

    var body: some View {
        let label = Text(text)
            .font(.system(size: 11 * TextScale.clamped(textScale), weight: .medium).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(style == .normal ? AnyShapeStyle(Self.tintText) : AnyShapeStyle(.secondary))
            .background(RoundedRectangle(cornerRadius: 4).fill(style == .normal ? AnyShapeStyle(.tint.opacity(0.12)) : style == .prep ? AnyShapeStyle(Color.fill) : AnyShapeStyle(.clear)))
            // With Increase Contrast every chip has an edge: a tint that faint barely shows its box.
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style == .outline || contrast == .increased ? Color.line : .clear))
        if let action {
            Button(action: action) {
                // At least 24 points to click, with the box itself no bigger. A row aligned on its top
                // lines up the box's own top, so the room around it doesn't push the box down.
                label.alignmentGuide(.top) { $0[.top] }
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(help).accessibilityLabel("\(help): \(text)")
        } else {
            label
        }
    }
}

struct Notice<Content: View>: View {
    enum Tone { case amber, red, grey, blue }
    let tone: Tone
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch tone {
            case .amber: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.amber)
            case .red: Image(systemName: "xmark.octagon").foregroundStyle(.red)
            case .grey: Image(systemName: "doc.text").foregroundStyle(.secondary)
            case .blue: ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(tone == .grey ? .callout : .body)
        .foregroundStyle(tone == .grey ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        // With Increase Contrast the box has an edge: its tint alone hardly stands off the window.
        .overlay { if contrast == .increased { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line) } }
    }

    private var background: Color {
        switch tone {
        case .amber: Color.orange.opacity(0.13)
        case .red: Color.red.opacity(0.09)
        case .grey: Color.fill
        case .blue: Color.accentColor.opacity(0.12)
        }
    }
}

/// A model failure in plain words, with the raw message behind Details when that says more.
struct ModelError: View {
    let raw: String
    var prefix = ""
    @ViewState private var details = false

    var body: some View {
        let plain = explainModelError(raw)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(prefix + plain).fixedSize(horizontal: false, vertical: true)
                if plain != raw { Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(.link) }
            }
            if details { Text(raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }
    }
}

extension View {
    /// Room at each end for what a screen says of itself in the middle of the toolbar (the recording's
    /// state, "Who’s who · …"). macOS 26 draws a capsule behind a toolbar item, hard against whatever is
    /// in it: without this the words run into the capsule's rounded ends.
    func toolbarStatusPadding() -> some View { padding(.horizontal, 12) }
}

/// A transcript beside a screen's own column (the call's notes, Who's who's voices): 340 points,
/// narrowing to 220 before that column goes under 380. In a narrow window there isn't room for both
/// at full width.
func sidePanelWidth(in paneWidth: CGFloat) -> CGFloat { min(340, max(220, paneWidth - 380)) }

/// The toolbar beside the meeting list when no meeting is open: a space, so the search button stays
/// over the list rather than sliding along to the window's end.
struct EmptyPaneToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
    }
}

extension ToolbarContent {
    /// A title or a status in the toolbar, without the glass capsule macOS 26 draws behind toolbar
    /// items: in one, words read as a button.
    @ToolbarContentBuilder func withoutCapsule() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// The pulsing red dot of a recording in progress; a steady one with Reduce Motion.
struct RecDot: View {
    @ViewState private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .opacity(dim && !reduceMotion ? 0.3 : 1)
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true } } }
    }
}

struct TodoCheckbox: View {
    let checked: Bool
    /// The to-do's text, so the button can be told apart from the next one without seeing it.
    var what = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                // At least 24 points to click, with the circle no bigger. A row aligned on its top
                // lines up the circle's own top, so the room around it doesn't push it below the text.
                .alignmentGuide(.top) { $0[.top] }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(checked ? "Mark as not done" : "Mark as done")
        .accessibilityLabel((checked ? "Mark as not done" : "Mark as done") + (what.isEmpty ? "" : ": \(what)"))
    }
}

/// 14 segments on a rough log scale (speech peaks sit around 0.05–0.5); the last two are "hot".
struct Meter: View {
    let label: String
    let level: Double?

    var body: some View {
        let l = level ?? 0
        let fraction = l > 0 ? min(1, max(0, (100 + 25 * log10(l)) / 100)) : 0
        let lit = Int((fraction * 14).rounded())
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<14, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < lit ? (i >= 12 ? Color.orange : Color.green) : Color.primary.opacity(0.12))
                        .frame(width: 4, height: 9)
                }
            }
        }
        // Read out as one thing with a level, rather than as a word and fourteen unnamed bars.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "You" ? "Your microphone’s level" : "\(label) audio level")
        .accessibilityValue(level == nil ? "Nothing yet" : lit == 0 ? "Silent" : "\(lit) of 14")
    }
}

struct SectionLabel: View {
    let text: String
    @AppStorage(TextScale.key) private var textScale = 1.0
    var body: some View {
        Text(text).font(.system(size: 11 * TextScale.clamped(textScale), weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PageTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 24, weight: .bold)).tracking(-0.4).textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Says something to VoiceOver that it wouldn't notice by itself: a toast, an answer arriving.
@MainActor func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
    guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
    NSAccessibility.post(element: window, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: priority.rawValue])
}

/// One toast at a time, gone after a couple of seconds. One that says something went wrong is
/// marked as such, stays longer, runs to several lines if it has to, and goes when it's clicked (or
/// pressed with VoiceOver). With Reduce Motion it fades rather than slides.
struct ToastView: View {
    let text: String
    var isError = false
    var dismiss: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isError { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
            Text(text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if isError { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: isError ? 560 : nil)
        // As round as a capsule on one line, and still a tidy box on three.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 17))
        .onTapGesture { if isError { dismiss() } }
        .help(isError ? "Click to dismiss" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isError ? .isButton : [])
        .accessibilityHint(isError ? "Dismisses this message" : "")
        .modifier(DismissOnPress(enabled: isError, dismiss: dismiss))
        .padding(.bottom, 80)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
    }
}

/// VoiceOver's press for a note that goes when pressed (an error's), and none for one that doesn't.
private struct DismissOnPress: ViewModifier {
    let enabled: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction { dismiss() } } else { content }
    }
}

/// How big the reading text is: summaries, answers, transcripts (the meeting's, the live one and Who's
/// who's), your notes, the Markdown editors, the meeting list, to-dos, times and section labels. View ›
/// Bigger Text and Smaller Text move it a step; everything else stays the size it is.
enum TextScale {
    static let key = "textScale"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.45, 1.6]

    static func bigger(_ scale: Double) -> Double { steps.first { $0 > scale + 0.001 } ?? steps.last! }
    static func smaller(_ scale: Double) -> Double { steps.last { $0 < scale - 0.001 } ?? steps.first! }
    /// A stored value that isn't one of the steps (edited by hand) is kept within them.
    static func clamped(_ scale: Double) -> Double { min(steps.last!, max(steps.first!, scale)) }
}

/// Settings' panes, as Settings is opened on them and remembers the last one shown.
enum SettingsPane: String {
    case general, calendar, people, models, summaries, storage, updates
    static let key = "settingsPane"
}

extension Font {
    /// One of the system's text styles (13 points for body, 10 for a caption) at the size View ›
    /// Bigger Text has set. On the Mac the styles themselves don't change size.
    static func scaled(_ style: NSFont.TextStyle, _ scale: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * TextScale.clamped(scale), weight: weight)
    }
}

/// Opens Settings on one of its panes, however it's pressed: a click, the keyboard or VoiceOver.
struct SettingsPaneLink: View {
    @Environment(\.openSettings) private var openSettings
    let pane: SettingsPane
    let title: String

    var body: some View {
        Button(title) { showSettingsPane(pane, openSettings) }
    }
}

/// The one place that says which pane Settings opens on.
@MainActor func showSettingsPane(_ pane: SettingsPane, _ open: OpenSettingsAction) {
    UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.key)
    open()
}

/// SwiftUI's State property wrapper. In the macOS 27 SDK `@State` is a macro whose plugin ships only
/// with Xcode, so with the Command Line Tools alone views use the property wrapper through this name.
typealias ViewState<Value> = SwiftUI.State<Value>

/// The words of a search or a Find: a meeting matches when it has all of them, anywhere.
func searchWords(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }

/// The text with each of the words marked wherever it appears, in any case or accent: the system's
/// find highlight, with the dark text it's made for (white on its see-through yellow can't be read
/// in a dark window).
func markingFound(_ text: AttributedString, _ words: [String]) -> AttributedString {
    var out = text
    for word in words where !word.isEmpty {
        var from = out.startIndex
        while from < out.endIndex, let found = out[from...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[found].backgroundColor = Color(nsColor: .findHighlightColor)
            out[found].foregroundColor = .black
            from = found.upperBound
        }
    }
    return out
}

func markingFound(_ text: String, _ words: [String]) -> AttributedString { markingFound(AttributedString(text), words) }

/// A text field that leaves ↑, ↓, Return and Escape to the view around it, takes the keyboard when it
/// appears, and gives it back to what had it when it goes. In a SwiftUI TextField the field editor
/// gets those keys first.
struct KeyedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var onMove: (Int) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}

    final class Field: NSTextField {
        /// What had the keyboard before this field took it.
        private weak var before: NSResponder?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                // Another field being typed in has the field editor as the responder: that field is what had it.
                let had = window.firstResponder
                if let editor = had as? NSText, editor.isFieldEditor { before = editor.delegate as? NSResponder } else { before = had }
                window.makeFirstResponder(self)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Going: the keyboard goes back, unless what had it has gone too (a meeting closed by opening another).
            if newWindow == nil, let window, let before, before === window || (before as? NSView)?.window === window {
                window.makeFirstResponder(before)
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        // Return through accessibility (VoiceOver's press) comes as the field's action.
        field.target = context.coordinator
        field.action = #selector(Coordinator.confirmed)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyedTextField
        init(parent: KeyedTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onReturn()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }

        @objc func confirmed() { parent.onReturn() }
    }
}
