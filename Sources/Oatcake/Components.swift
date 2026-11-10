// Small shared pieces of the design: avatars, chips, notices, the recording dot, checkboxes, meters.

import OatcakeCore
import SwiftUI

extension Color {
    static let amber = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.63, green: 0.28, blue: 0, alpha: 1) })
    static let fill = Color.primary.opacity(0.06)
    static let line = Color.primary.opacity(0.09)
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    var remember = true
    var color: Color?

    var body: some View {
        let p = person(name, remember: remember)
        Text(p.initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color ?? p.color))
    }
}

/// A time like 12:34 in a small rounded box; tappable when it jumps somewhere.
struct Chip: View {
    enum Style { case normal, prep, outline, pending }
    let text: String
    var style = Style.normal
    var action: (() -> Void)?

    var body: some View {
        let label = Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(style == .normal ? AnyShapeStyle(.tint) : style == .pending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .background(RoundedRectangle(cornerRadius: 4).fill(style == .normal ? AnyShapeStyle(.tint.opacity(0.12)) : style == .prep ? AnyShapeStyle(Color.fill) : AnyShapeStyle(.clear)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style == .outline ? Color.line : .clear))
        if let action {
            Button(action: action) { label }.buttonStyle(.plain).help("Jump to this moment in the transcript")
        } else {
            label
        }
    }
}

struct Notice<Content: View>: View {
    enum Tone { case amber, red, grey, blue }
    let tone: Tone
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch tone {
            case .amber: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.amber)
            case .red: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
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

/// The pulsing red dot of a recording in progress.
struct RecDot: View {
    @ViewState private var dim = false
    var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .opacity(dim ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true } }
    }
}

struct TodoCheckbox: View {
    let checked: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .help(checked ? "Mark as not done" : "Mark as done")
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
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
}

struct PageTitle: View {
    let text: String
    var size: CGFloat = 24
    var body: some View {
        Text(text).font(.system(size: size, weight: .bold)).tracking(-0.4).textSelection(.enabled)
    }
}

/// One toast at a time, gone after a couple of seconds.
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 80)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// SwiftUI's State property wrapper. In the macOS 27 SDK `@State` is a macro whose plugin ships only
/// with Xcode, so with the Command Line Tools alone views use the property wrapper through this name.
typealias ViewState<Value> = SwiftUI.State<Value>
