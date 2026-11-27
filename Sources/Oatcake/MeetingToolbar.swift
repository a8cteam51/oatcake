import OatcakeCore
import SwiftUI

extension MeetingView {
    // MARK: Toolbar

    /// Over the meeting: the tabs at the left; at the right, how saving is going, while there's
    /// something to say, and one menu with everything that can be done to it. (.navigation would
    /// put the tabs over the meeting list.)
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        // The tabs are a new toolbar item when the draft's tab comes or goes. Changed in place, the
        // item kept the width of three when Draft for Sharing… added the fourth as its sheet closed,
        // and the four were squeezed into it until the draft was written.
        if showsDraftTab {
            ToolbarItem(placement: .automatic) { tabPicker }
        } else {
            ToolbarItem(placement: .automatic) { tabPicker }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
        // How saving is going stays up here, in sight wherever the note is scrolled to. Words, not a
        // button: no capsule behind them.
        if markdown || status == .todo || status == .failed {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Text(status.text)
                        .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if status == .failed { Button("Try again") { flush() }.buttonStyle(.link) }
                }
                .font(.callout)
                .toolbarStatusPadding()
            }
            .withoutCapsule()
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                // Every item with its icon: a share item always shows one, so the rest do too.
                actions.labelStyle(.titleAndIcon)
            } label: {
                // Named on the image too: a toolbar menu is read out by its image's name.
                Label { Text("More") } icon: { Image(systemName: "ellipsis").accessibilityLabel("More") }
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
            .help("Draft for sharing, regenerate, rename people, copy, share, rename, move, show in Finder or move to the Trash")
        }
    }

    /// The meeting's menu: the same commands as the Meeting menu and its right-click menus.
    private var actions: some View {
        MeetingMenuItems(model: model, node: node, local: (menuState, perform), showsDraftShortcut: true)
    }

    /// What this meeting can do just now, for the menus outside it.
    var menuState: OpenMeeting {
        OpenMeeting(view: viewID, path: path, tab: tab, tabs: tabs, hasSummary: !(files?[.summary] ?? "").trimmed.isEmpty,
                    hasTranscript: !(files?[.transcript] ?? "").trimmed.isEmpty, canRenameSpeakers: canRenameSpeakers,
                    template: meta.template, canFindNext: finding && tab == .transcript && !markdown, shareText: shareText)
    }

    /// Summary, Transcript, My notes and Draft (for sharing), in the toolbar over the meeting.
    private var tabPicker: some View {
        Picker("Tab", selection: Binding(get: { tab }, set: { switchTab($0) })) {
            Text("Summary").tag(MeetingTab.summary).help("⌘1")
            Text("Transcript").tag(MeetingTab.transcript).help("⌘2")
            Text("My notes").tag(MeetingTab.notes).help("⌘3")
            // Short: the toolbar gives each tab the width of the widest.
            if showsDraftTab { Text("Draft").tag(MeetingTab.draft).help("Draft for sharing (⌘4)") }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// What Copy and Share take: the tab you're on, as Markdown under the meeting's title and date.
    private var shareText: String {
        let part = { (key: FileKey) in forReading(files?[key] ?? "").trimmed }
        var parts = ["# \(meetingTitle(node))", metaLine]
        switch tab {
        case .summary:
            if model.config.todosEnabled, !part(.todos).isEmpty { parts.append("## To-dos\n\n\(part(.todos))") }
            parts.append(part(.summary))
        case .transcript: parts.append(part(.transcript))
        case .notes: parts.append(part(.notes))
        case .draft: parts.append(part(.draft))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    func copy(_ what: String) {
        // Formatted for documents and mail, and the Markdown for anything that only takes plain text.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardHTML(shareText), forType: .html)
        pasteboard.setString(shareText, forType: .string)
        // Said in a note: the menu it was chosen from has closed.
        model.toast("Copied the \(what)")
    }

    /// A meeting saved without checking who's who has Check who's who… instead, until Keep these names.
    private var canRenameSpeakers: Bool {
        guard !speakers.isEmpty else { return false }
        guard let id = meta.recording else { return true }
        return !model.jobs.unchecked.contains { $0.id == id }
    }
}
