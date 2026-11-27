// What can be done to a meeting, one set of commands wherever they're offered: the meeting's ⋯ menu,
// the Meeting menu in the menu bar, and the right-click menus of the meeting list and the sidebar.

import OatcakeCore
import SwiftUI

/// What the menus outside a meeting ask it to do. It does them itself: they need what it has read.
enum MeetingCommand: Equatable {
    case tab(MeetingTab)
    case find, findNext, findPrevious
    case draftForSharing
    case regenerate(SummaryPart, SummaryTemplateChoice)
    case renameSpeakers
    case copy
}

/// A command for the open meeting. The nonce makes the same command twice count.
struct MeetingRequest: Equatable {
    var command: MeetingCommand
    var nonce = UUID()
}

/// What the open meeting can do just now, as it tells the menus outside it.
struct OpenMeeting: Equatable {
    /// The meeting's view that says so: a meeting opened again (or reached by a link to it) is a new view.
    var view: UUID
    var path: String
    var tab: MeetingTab
    /// The tabs it shows: Draft only with a draft for sharing.
    var tabs: [MeetingTab]
    var hasSummary: Bool
    var hasTranscript: Bool
    var canRenameSpeakers: Bool
    /// The summary template it was last regenerated with.
    var template: String?
    /// Find is open on the transcript, where it steps from one line to the next.
    var canFindNext: Bool
    /// What Copy and Share take.
    var shareText: String
}

extension MeetingTab {
    /// What Copy and Share take from this tab, in words.
    func contents(todos: Bool) -> String {
        switch self {
        case .summary: todos ? "summary and to-dos" : "summary"
        case .transcript: "transcript"
        case .notes: "notes"
        case .draft: "draft for sharing"
        }
    }

    /// The tab as a menu names it.
    var menuName: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .notes: "My Notes"
        case .draft: "Draft"
        }
    }
}

/// One meeting's commands. Those that act on the tab showing (Copy, Regenerate…) are greyed out on a
/// tab they don't apply to, and for a meeting that isn't open.
struct MeetingMenuItems: View {
    let model: AppModel
    /// nil in the Meeting menu while no meeting is open: every item is there, greyed out.
    let node: TreeNode?
    /// The ⋯ menu's own meeting, and how it does what's chosen. Anywhere else, the open meeting as it
    /// last said, which is sent what's chosen.
    var local: (open: OpenMeeting, perform: (MeetingCommand) -> Void)?
    var showsDraftShortcut = false

    var body: some View {
        let open = local?.open ?? model.meetingInView.flatMap { $0.path == node?.path ? $0 : nil }
        let perform = local?.perform ?? { model.request($0) }
        let path = node?.path ?? ""
        let summarising = model.jobs.summarising.contains(path)
        let todos = model.config.todosEnabled
        let canDraft = open.map { ($0.tab == .summary || $0.tab == .draft) && $0.hasSummary } ?? false
        let canRegenerate = open.map { $0.tab == .summary && $0.hasSummary && $0.hasTranscript } ?? false
        let templates = model.config.summaryTemplateChoices

        // Writing it again first, then taking it elsewhere, then the meeting itself.
        Button { perform(.draftForSharing) } label: { Label("Draft for Sharing…", systemImage: "square.and.pencil") }
            .keyboardShortcut(showsDraftShortcut ? KeyboardShortcut("d", modifiers: [.command, .shift]) : nil)
            .disabled(!canDraft || summarising || model.jobs.drafting.contains(path))
            .help(todos ? "Write this meeting’s summary and to-dos again for other people to read"
                  : "Write this meeting’s summary again for other people to read")
        if templates.isEmpty {
            Button { perform(.regenerate(.summary, .meetings)) } label: { Label("Regenerate Summary", systemImage: "sparkles") }
                .disabled(!canRegenerate || summarising)
                .help("Write the summary again with the current instructions in Settings")
        } else {
            // Ticked: what this meeting's summary is written with now.
            let current = model.config.summaryTemplate(named: open?.template)?.name
            Menu {
                Toggle("Default", isOn: Binding(get: { current == nil }, set: { _ in perform(.regenerate(.summary, .picked(nil))) }))
                Divider()
                ForEach(templates, id: \.name) { t in
                    Toggle(t.name, isOn: Binding(get: { current == t.name }, set: { _ in perform(.regenerate(.summary, .picked(t.name))) }))
                }
            } label: { Label("Regenerate Summary", systemImage: "sparkles") }
                .disabled(!canRegenerate || summarising)
                .help("Write the summary again, with a template if you pick one")
        }
        if todos {
            Button { perform(.regenerate(.todos, .meetings)) } label: { Label("Regenerate To-dos", systemImage: "checklist") }
                .disabled(!canRegenerate || summarising)
                .help("Write the to-dos again with the current instructions in Settings")
        }
        Button { perform(.renameSpeakers) } label: { Label("Rename People…", systemImage: "person.2") }
            .disabled(!(open?.canRenameSpeakers ?? false) || summarising)
            .help(todos ? "Change who’s who in this meeting: the names in its transcript, summary and to-dos"
                  : "Change who’s who in this meeting: the names in its transcript and summary")
        Divider()
        let tab = open?.tab ?? .last
        Button { perform(.copy) } label: { Label("Copy \(tab.menuName)", systemImage: "doc.on.doc") }
            .disabled(open == nil)
            .help("Copy the \(tab.contents(todos: todos)), formatted (as Markdown where only plain text can go)")
        if let open, let node {
            ShareLink(item: open.shareText, subject: Text(meetingTitle(node))) { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Send the \(tab.contents(todos: todos)) with Mail, Messages or another app")
        } else {
            Button {} label: { Label("Share", systemImage: "square.and.arrow.up") }.disabled(true)
        }
        Divider()
        Button { model.renaming = node } label: { Label("Rename…", systemImage: "pencil") }
            .disabled(node == nil)
            .help("Change the meeting’s title and its folder’s name")
        MoveMenu(model: model, paths: node.map { [$0.path] } ?? [])
        Button { model.library.reveal(path) } label: { Label("Show in Finder", systemImage: "arrow.up.forward.square") }
            .disabled(node == nil)
            .help("Show this meeting’s folder in Finder")
        Divider()
        Button { if let node { model.trash([node]) } } label: { Label("Move to Trash", systemImage: "trash") }
            .disabled(node == nil)
    }
}

/// Move To: the top level of the Meetings folder, or any folder in it. The keyboard's way to file
/// meetings, where the mouse drags them.
struct MoveMenu: View {
    let model: AppModel
    let paths: [String]
    var title = "Move To"

    var body: some View {
        // Where they are already, when they're all in one place.
        let from = Set(paths.map(parentOf))
        Menu {
            Button("Meetings (top level)") { model.library.move(paths, into: "") }.disabled(from == [""])
            let folders = model.library.tree?.allFolders ?? []
            if !folders.isEmpty { Divider() }
            ForEach(folders) { f in
                Button(folderPath(f.path)) { model.library.move(paths, into: f.path) }.disabled(from == [f.path])
            }
        } label: { Label(title, systemImage: "folder") }
            .disabled(paths.isEmpty)
    }
}
