import OatcakeCore
import SwiftUI

/// The middle column: the selected folder's meetings, newest first (every meeting for the top
/// level), or the meetings a search finds anywhere.
struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    /// Passed in rather than read here: inside the split view, this column doesn't always see the
    /// model change by itself.
    let folder: TreeNode?
    /// The whole Meetings folder, which search looks through.
    let root: TreeNode?
    @ViewState private var renaming: TreeNode?
    @ViewState private var draft = ""
    @ViewState private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        // The top level lists every meeting, each labelled with the folder it's in; so does a search.
        let search = query.trimmed
        let everything = !search.isEmpty || (folder?.path.isEmpty ?? true)
        let rows = search.isEmpty ? listedIn(folder) : found(search)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(!search.isEmpty ? "Search" : everything ? "All meetings" : baseName(folder!.path)).font(.headline).lineLimit(1)
                Spacer()
                Text("\(everything || parentOf(folder!.path).isEmpty ? "" : folderPath(parentOf(folder!.path)) + " · ")\(rows.count) meeting\(rows.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
                TextField("Search all meetings", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onKeyPress(.escape) {
                        query = ""
                        searching = false
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.fill))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Search titles, folders and summaries (⌥⌘F)")
            Divider()
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(!search.isEmpty ? "No meetings match “\(search)”." : everything ? "No meetings yet." : "No meetings in this folder yet.")
                        .foregroundStyle(.secondary)
                    if search.isEmpty {
                        Button { model.newRecording() } label: { Label("Record here", systemImage: "circle.fill") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Picking a meeting leaves this list as it is, rather than swapping it for the meeting's folder.
                List(selection: Binding(get: { selectedPath }, set: { if let p = $0 { model.selectMeeting(p) } })) {
                    ForEach(rows) { row($0, everything: everything, folder: folder?.path ?? "").tag($0.path) }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.searchRequest) { searching = true }
        .alert("Rename meeting", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $draft)
            Button("Rename") { if let node = renaming { model.retitle(node.path, to: draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes the meeting’s title and its folder’s name.")
        }
    }

    private var selectedPath: String? {
        if case .meeting(let path, _) = model.selection { return path }
        return nil
    }

    /// Every meeting whose title, folder or summary preview has all the words typed, newest first.
    private func found(_ search: String) -> [TreeNode] {
        let words = search.split(separator: " ").map(String.init)
        return listedIn(root).filter { m in
            let text = "\(meetingTitle(m)) \(folderPath(parentOf(m.path))) \(m.preview)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private func row(_ m: TreeNode, everything: Bool, folder: String) -> some View {
        let date = meetingDate(m)
        let title = meetingTitle(m)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(date.map(longDate) ?? m.name).fontWeight(.semibold).lineLimit(1)
                if let date {
                    Text("·").foregroundStyle(.tertiary)
                    Text(hhmm(date)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if m.granola {
                    Text("Granola").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.fill))
                }
            }
            if everything {
                let parent = parentOf(m.path)
                if parent.isEmpty {
                    Text(title).fontWeight(.medium).lineLimit(1)
                } else {
                    (Text(folderPath(parent)).fontWeight(.medium) + Text(sameAsFolder(title, parent) ? "" : " · \(title)").foregroundStyle(.secondary))
                        .lineLimit(1)
                }
            } else if !sameAsFolder(title, folder) {
                Text(title).fontWeight(.medium).lineLimit(1)
            }
            if !m.preview.isEmpty {
                Text(m.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .draggable(dragPrefix + m.path)
        .contextMenu {
            Button("Rename…") { draft = title; renaming = m }
            Button("Show in Finder") { model.reveal(m.path) }
            Divider()
            Button("Move to Trash") { model.trash(m) }
        }
    }
}
