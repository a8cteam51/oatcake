import AppKit
import OatcakeCore
import SwiftUI
import UserNotifications

struct OatcakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Oatcake", id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 880)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: delegate.model) }

        // Settings is its own window, like a Mac app's Settings. Changes apply as they're made.
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// File › New Recording, and Edit › Find in Transcript and Search Meetings.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some Commands {
        // The menus are built at launch, before (and whether or not) the window is: this is where
        // the app learns how to open it, for the menu bar item, reminders and launch itself.
        let _ = model.openMainWindow = { openWindow(id: "main") }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { model.newRecording() }.keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Transcript") { model.findRequest += 1 }.keyboardShortcut("f")
            Button("Search Meetings") { model.searchMeetings() }.keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Reminders.register()
        MainActor.assumeIsolated { model.start() }
        // Oatcake always opens with its window. macOS remembers a window that was closed when the app
        // quit (it can be quit from the menu bar that way) and would otherwise open with nothing to see.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { self.model.showWindow() }
            }
        }
    }

    /// Closing the window quits, unless a call is being recorded or the menu bar is showing your
    /// next call: then Oatcake stays in the menu bar (its menu reopens the window, or quits).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !model.isRecording && !model.showsNextCallInMenuBar }
    }

    /// Clicking the Dock icon while Oatcake is only in the menu bar brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model.showWindow() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.stopAllRecorders() }
    }

    /// Reminders show even while Oatcake is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // "On a call?": its button starts recording; clicking it opens New recording.
        if response.notification.request.content.categoryIdentifier == Reminders.callCategory {
            await MainActor.run {
                if response.actionIdentifier == Reminders.recordAction {
                    model.recordCall()
                } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                    model.newRecording(model.currentEvent)
                }
            }
            return
        }
        guard let event = Reminders.event(from: response) else { return }
        await MainActor.run {
            if response.actionIdentifier == Reminders.startAction {
                model.startFromEvent(event)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                model.openEvent(event)
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 520)
        } detail: {
            if showsList {
                HSplitView {
                    MeetingListView(folder: model.tree?.find(model.folder) ?? model.tree, root: model.tree)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 560)
                    DetailView()
                        .frame(minWidth: 420, maxWidth: .infinity)
                        .layoutPriority(1)
                }
            } else {
                DetailView()
            }
        }
        .overlay(alignment: .bottom) {
            if let text = model.toastText { ToastView(text: text).allowsHitTesting(false) }
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
               presenting: model.confirmation) { confirmation in
            Button(confirmation.cancel, role: .cancel) {}
            Button(confirmation.ok, role: .destructive) {
                // A failure (say, the recording had already stopped) is shown rather than lost.
                Task { do { try await confirmation.action() } catch { model.toast(error.localizedDescription) } }
            }
        } message: { confirmation in
            Text(confirmation.text)
        }
    }

    private var showsList: Bool {
        switch model.selection {
        case nil, .meeting, .folder: true
        default: false
        }
    }
}

/// The right-hand pane.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .meeting(let path, let jump):
                if let node = model.tree?.find(path), node.kind == .meeting {
                    MeetingView(node: node, jump: jump)
                        .id(path + (jump.map { $0.nonce.uuidString } ?? ""))
                        .overlay(alignment: .bottom) { AskBar(path: path) }
                } else {
                    blank
                }
            case .todos:
                TodosView()
            case .new(let event, let key):
                NewRecordingView(event: event).id(key)
            case .live:
                if let rec = model.live { LiveView(rec: rec) } else { blank }
            case .job(let id):
                if let rec = model.pending.first(where: { $0.id == id }) {
                    if rec.state == .processed {
                        ReviewView(rec: rec).id(rec.id)
                    } else {
                        ProcessingView(rec: rec).id(rec.id)
                    }
                } else {
                    blank
                }
            case .folder, nil:
                blank
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An empty folder says so (with Record here) in the middle column; this pane stays blank.
    private var blank: some View {
        Text(listedIn(model.tree?.find(model.folder) ?? model.tree).isEmpty ? "" : "Select a meeting")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
