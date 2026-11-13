// Sharing in the window: Settings › Sharing, where you sign in to Spacefast and make your Space,
// and the sheet a folder's "Share…" opens, where you say who can read it.

import OatcakeCore
import SwiftUI

/// Settings › Sharing.
struct SharingSettings: View {
    @Environment(AppModel.self) private var model
    /// The team picked for your Space: the first one until you choose.
    @ViewState private var team: Spacefast.Team?
    /// The Space picked from those the team already has: the first one until you choose.
    @ViewState private var space: Spacefast.SpaceInfo?

    var body: some View {
        Section {
            if !model.sharingSignedIn {
                LabeledContent {
                    if model.sharingSigningIn {
                        Button("Cancel") { model.cancelSpacefastSignIn() }
                    } else {
                        Button("Sign In with Spacefast…") { model.signInToSpacefast() }
                    }
                } label: {
                    Text(model.sharingSigningIn ? "Waiting for you to sign in" : "Not signed in")
                    if model.sharingSigningIn { Text("Approve Oatcake on the page that opened in your browser.") }
                }
            } else if model.sharing.space.trimmed.isEmpty {
                if let teams = model.sharingTeams {
                    Picker("Team", selection: Binding(get: { chosenTeam }, set: { team = $0; space = nil })) {
                        ForEach(teams) { Text($0.name).tag(Optional($0)) }
                    }
                    .disabled(model.sharingCreating || teams.count < 2)
                    .task(id: chosenTeam?.id) { if let chosenTeam { await model.lookAtSpaces(in: chosenTeam) } }
                    if let chosenTeam, let spaces = model.sharingSpaces[chosenTeam.id], !spaces.isEmpty {
                        let picked = space.flatMap { spaces.contains($0) ? $0 : nil } ?? spaces.first
                        Picker("Space", selection: Binding(get: { picked }, set: { space = $0 })) {
                            ForEach(spaces) { Text(spaceName($0, among: spaces)).tag(Optional($0)) }
                        }
                        .disabled(model.sharingCreating)
                        LabeledContent {
                            Button("Use This Space") { if let picked { model.useSharingSpace(picked) } }.disabled(model.sharingCreating)
                        } label: {
                            Text("A Space you already have")
                            Text("For the Space Oatcake publishes to from another Mac, say. Oatcake makes it hold your synced folders and nothing else.")
                        }
                    }
                    LabeledContent {
                        Button(model.sharingCreating ? "Creating…" : "Create Oatcake Space") { if let chosenTeam { model.createSharingSpace(in: chosenTeam) } }
                            .disabled(model.sharingCreating || chosenTeam == nil)
                    } label: {
                        Text("A new Space")
                        Text(teams.isEmpty ? "Your Spacefast account has no team to make a Space in." : "A private Space called Oatcake is made in this team. Everyone in the team can read all of it, so choose one with only you in it.")
                    }
                } else if model.sharingProblem == nil {
                    LabeledContent("Team") { ProgressView().controlSize(.small) }
                }
                signOut
            } else {
                LabeledContent {
                    if let address = model.sharing.address, !address.isEmpty, let url = URL(string: address) { Button("Open") { NSWorkspace.shared.open(url) } }
                } label: {
                    Text("Your Space")
                    Text(model.sharing.address.flatMap { $0.isEmpty ? nil : $0 } ?? model.sharing.space).textSelection(.enabled)
                    if let others = model.sharingOthers { Text(others).foregroundStyle(.red) }
                }
                signOut
            }
            if let problem = model.sharingProblem {
                LabeledContent {
                    if model.sharingSignedIn {
                        Button("Try Again") {
                            Task {
                                await model.lookAtSharing()
                                if let chosenTeam { await model.lookAtSpaces(in: chosenTeam) }
                            }
                        }
                    }
                } label: {
                    Text(problem).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Your Space on Spacefast")
        } footer: {
            Text("Optional. Oatcake works the same without it, and nothing here is on unless you sign in. Sharing puts the folders you choose on a Space of your own at spacefast.com, as pages only you can open until you share a folder with someone. Nothing is sent unless a folder is set to sync. You sign in on Spacefast’s own page in your browser; Oatcake never sees your password.")
                .settingsHint()
        }
        .task(id: model.sharingSignedIn) { await model.lookAtSharing() }

        // Nothing about folders until sharing is set up, or while some are still marked to sync.
        if model.sharingSetUp || !model.sharing.folders.isEmpty { syncedFolders }
    }

    private var syncedFolders: some View {
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

    /// The team a Space is chosen or made in.
    private var chosenTeam: Spacefast.Team? {
        let teams = model.sharingTeams ?? []
        return team.flatMap { teams.contains($0) ? $0 : nil } ?? teams.first
    }

    /// A Space by its name, with where it's served when another in the list has the same name.
    private func spaceName(_ space: Spacefast.SpaceInfo, among spaces: [Spacefast.SpaceInfo]) -> String {
        guard spaces.filter({ $0.name == space.name }).count > 1, let host = URL(string: space.address)?.host else { return space.name }
        return "\(space.name) (\(host))"
    }

    private var signOut: some View {
        LabeledContent {
            Button("Sign Out") { model.signOutOfSpacefast() }
        } label: {
            Text("Signed in to Spacefast")
        }
    }

    private var status: String {
        if model.sharingBusy { return "Syncing…" }
        guard let last = parseISO(model.sharing.lastSync) else { return "Not synced yet" }
        return "Last synced \(last.formatted(date: .abbreviated, time: .shortened))"
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
                    PendingViewers(path: path)
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

    private func change(_ change: (inout FolderSharing) -> Void) { model.changeFolderSharing(path, change) }

    private func add() {
        switch model.inviteReader(email: email, name: name, to: path) {
        case .problem(let text): problem = text
        case .cancelled: problem = ""
        case .waiting:
            problem = ""
            // After the question has been answered: a field that's still being typed in keeps its text otherwise.
            Task {
                name = ""
                email = ""
            }
        }
        emailFocused = true
    }
}

/// The people about to be invited to a folder, each with the chance to take it back.
struct PendingViewers: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        ForEach(model.pendingViewers.filter { $0.path == path }) { pending in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Inviting \(pending.email) in a few seconds").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Undo") { model.undoInvite(pending) }.accessibilityLabel("Undo inviting \(pending.email)")
            }
        }
    }
}

/// Above a folder's meetings: who can view it on Spacefast, and a field to add someone. Only there
/// once sharing is set up; a folder that isn't synced offers to be.
struct FolderViewers: View {
    @Environment(AppModel.self) private var model
    let path: String
    @ViewState private var email = ""
    @ViewState private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.sharing.isSynced(path) {
                let viewers = model.sharing.readers(of: path).map(\.email)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: viewers.isEmpty ? "arrow.triangle.2.circlepath" : "person.2.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(viewers.isEmpty ? "On your Space. Only you can view it." : "Viewers: \(viewers.joined(separator: ", "))")
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Share…") { model.shareFolder(path) }.buttonStyle(.link).help("Names, removing someone, and whether transcripts are shared")
                }
                HStack(spacing: 6) {
                    TextField("Add a viewer", text: $email, prompt: Text("Add a viewer’s email address"))
                        .textFieldStyle(.roundedBorder).labelsHidden().onSubmit(add)
                        .onChange(of: email) { problem = "" }
                    Button("Add", action: add).disabled(email.trimmed.isEmpty)
                }
                if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
                PendingViewers(path: path)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Only on this Mac").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Sync to Spacefast") { model.setFolderSynced(path, true) }.help("Puts this folder on your Space, where you can then add viewers")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func add() {
        switch model.inviteReader(email: email, to: path) {
        case .problem(let text): problem = text
        case .cancelled: problem = ""
        case .waiting:
            problem = ""
            // After the question has been answered: a field that's still being typed in keeps its text otherwise.
            Task { email = "" }
        }
    }
}
