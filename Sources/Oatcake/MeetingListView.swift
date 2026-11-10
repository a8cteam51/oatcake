import OatcakeCore
import SwiftUI

/// The middle column: the selected folder's meetings, newest first (every meeting for the top level).
struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var renaming: TreeNode?
    @ViewState private var draft = ""

    var body: some View {
        let folder = model.tree?.find(model.folder) ?? model.tree
        // The top level lists every meeting, each labelled with the folder it's in.
        let everything = folder?.path.isEmpty ?? true
        let rows = listedIn(folder)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(everything ? "All meetings" : baseName(folder!.path)).font(.headline).lineLimit(1)
                Spacer()
                Text("\(everything || parentOf(folder!.path).isEmpty ? "" : folderPath(parentOf(folder!.path)) + " · ")\(rows.count) meeting\(rows.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(everything ? "No meetings yet." : "No meetings in this folder yet.").foregroundStyle(.secondary)
                    Button { model.selection = model.live != nil ? .live : .new(nil) } label: {
                        Label("Record here", systemImage: "circle.fill")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { selectedPath }, set: { if let p = $0 { model.openMeeting(p) } })) {
                    ForEach(rows) { row($0, everything: everything, folder: folder?.path ?? "").tag($0.path) }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Folder name", text: $draft)
            Button("Rename") { if let node = renaming { model.rename(node.path, to: draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the meeting's folder.")
        }
    }

    private var selectedPath: String? {
        if case .meeting(let path, _) = model.selection { return path }
        return nil
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
            Button("Rename…") { draft = m.name; renaming = m }
            Button("Show in Finder") { model.reveal(m.path) }
            Divider()
            Button("Move to Trash") { model.trash(m) }
        }
    }
}
