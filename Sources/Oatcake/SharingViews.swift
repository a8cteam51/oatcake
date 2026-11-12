// Sharing in the window: Settings › Sharing, where your Spacefast Space and its key go, and the
// sheet a folder's "Share…" opens, where you say who can read it.

import OatcakeCore
import SwiftUI

/// Settings › Sharing.
struct SharingSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var space = ""
    @ViewState private var checking = false
    @ViewState private var checked: (ok: Bool, text: String)?

    var body: some View {
        Section {
            TextField("Space", text: $space, prompt: Text("its name, or its id (spc_…)"))
                .onSubmit(saveSpace)
                .onChange(of: space) { checked = nil }
            VStack(alignment: .leading, spacing: 6) {
                Text("Key")
                SecretField(name: .spacefast, placeholder: "sfa_…")
            }
            LabeledContent {
                Button(checking ? "Checking…" : "Check") { check() }.disabled(checking || space.trimmed.isEmpty)
            } label: {
                Text("Check it works")
                if let checked { Text(checked.text).foregroundStyle(checked.ok ? Color.secondary : Color.red) }
            }
        } header: {
            Text("Your Space on Spacefast")
        } footer: {
            Text("Sharing puts the folders you choose on a Space of your own at spacefast.com, as pages only you can open until you share a folder with someone. Nothing is sent unless a folder is set to sync. Make a private Space in a team with nobody else in it (everyone in the team that owns a Space can read all of it), then an API key limited to that Space which can publish and manage access.")
                .settingsHint()
        }
        .onAppear { space = model.sharing.space }
        .onDisappear(perform: saveSpace)

        Section {
            let folders = model.sharing.folders.sorted { $0.key < $1.key }
            if folders.isEmpty {
                Text("No folders sync yet. Right-click a folder in the sidebar and choose Sync to Spacefast.").settingsHint()
            }
            ForEach(folders, id: \.key) { path, sharing in
                LabeledContent {
                    Button("Share…") { model.shareFolder(path) }
                } label: {
                    Text(folderPath(path))
                    Text("\(sharing.readers.isEmpty ? "Only you" : sharing.readers.count == 1 ? "1 person" : "\(sharing.readers.count) people") · \(sharing.transcript ? "summaries, to-dos and transcripts" : "summaries and to-dos")")
                }
            }
            LabeledContent {
                Button(model.sharingBusy ? "Syncing…" : "Sync Now") { model.syncSharingSoon(always: true) }
                    .disabled(model.sharingBusy || !model.sharingSetUp)
            } label: {
                Text(status)
                if let error = model.sharing.lastError { Text(error).foregroundStyle(.red) }
            }
        } header: {
            Text("Synced folders")
        } footer: {
            Text("A synced folder is published again whenever something in it changes: its summaries and to-dos, and its transcripts if you say so. Your own notes and the call audio are never sent. A folder inside a synced folder syncs with it, and is shared with the same people.")
                .settingsHint()
        }
    }

    private var status: String {
        if model.sharingBusy { return "Syncing…" }
        guard let last = parseISO(model.sharing.lastSync) else { return "Not synced yet" }
        return "Last synced \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    private func saveSpace() {
        guard space.trimmed != model.sharing.space else { return }
        model.changeSharing {
            $0.space = space.trimmed
            // Another Space has none of this one's pages or readers.
            $0.published = nil
            $0.address = nil
        }
    }

    private func check() {
        saveSpace()
        checking = true
        Task {
            checked = await model.checkSharing()
            checking = false
        }
    }
}

/// Who a folder is shared with. Changes are saved, and the Space brought into line, as they're made.
struct ShareFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String
    @ViewState private var name = ""
    @ViewState private var email = ""
    @ViewState private var problem = ""
    @FocusState private var emailFocused: Bool

    var body: some View {
        let own = model.sharing.folders[path]
        let above = model.sharing.syncedFolder(over: parentOf(path)).flatMap { path.contains("/") ? $0 : nil }
        let inherited = above.map { model.sharing.readers(of: $0) } ?? []
        // A folder inside a synced one has that folder's choice about transcripts until it's given its own.
        let transcript = own?.transcript ?? above.flatMap { model.sharing.folders[$0]?.transcript } ?? false
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share “\(baseName(path))”").font(.title3.weight(.semibold))
                Text("The people here can read every meeting in this folder and in the folders inside it. Spacefast emails each of them a link; they don’t need an account.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let address = model.sharing.address, !address.isEmpty {
                let link = address + (address.hasSuffix("/") ? "" : "/") + sharePath(path) + "/"
                HStack(spacing: 6) {
                    Text(link).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string); model.toast("Copied the folder’s address") } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy the folder’s address").accessibilityLabel("Copy the folder’s address")
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if (own?.readers ?? []).isEmpty && inherited.isEmpty {
                        Text("Only you can read this folder.").foregroundStyle(.secondary)
                    }
                    ForEach(own?.readers ?? [], id: \.email) { reader in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reader.name.isEmpty ? reader.email : reader.name)
                                if !reader.name.isEmpty { Text(reader.email).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Remove") { change { $0.readers.removeAll { $0.email == reader.email } } }
                                .accessibilityLabel("Remove \(reader.name.isEmpty ? reader.email : reader.name)")
                        }
                    }
                    if !inherited.isEmpty, let above {
                        Text("Also read by \(inherited.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ")), because “\(folderPath(above))” is shared with them.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        TextField("Name", text: $name).frame(width: 150)
                        TextField("Email address", text: $email).focused($emailFocused).onSubmit(add)
                        Button("Add", action: add).disabled(email.trimmed.isEmpty)
                    }
                    if !problem.isEmpty { Text(problem).font(.callout).foregroundStyle(.red) }
                }
                .padding(6)
            }
            Toggle(isOn: Binding(get: { transcript }, set: { on in change { $0.transcript = on } })) {
                Text("Include transcripts")
                Text("Off, only each meeting’s summary and to-dos are shared. A transcript holds everything everyone said.")
            }
            Text("If this folder is renamed or moved, it stops being shared with anyone and you add people again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let error = model.sharing.lastError { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) } else if model.sharingBusy { ProgressView().controlSize(.small); Text("Syncing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Changes this folder's own settings. A folder inside a synced one gets settings of its own the first time.
    private func change(_ change: (inout FolderSharing) -> Void) {
        model.changeSharing { state in
            let above = state.syncedFolder(over: parentOf(path)).flatMap { path.contains("/") ? $0 : nil }
            var folder = state.folders[path] ?? FolderSharing(transcript: above.flatMap { state.folders[$0]?.transcript } ?? false)
            change(&folder)
            state.folders[path] = folder
        }
    }

    private func add() {
        let reader = ShareReader(email: email, name: name)
        // Enough to catch a slip; Spacefast is the judge of whether it's an address.
        guard reader.email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else {
            problem = "That doesn’t look like an email address."
            return
        }
        problem = ""
        change { folder in
            folder.readers.removeAll { $0.email == reader.email }
            folder.readers.append(reader)
        }
        name = ""
        email = ""
        emailFocused = true
    }
}
