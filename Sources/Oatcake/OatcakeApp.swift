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

        // Settings is its own window, like a Mac app's Settings. Changes apply as they're made.
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Reminders.register()
        MainActor.assumeIsolated { model.start() }
    }

    /// Closing the window quits, unless a call is being recorded.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !model.isRecording }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.stopAllRecorders() }
    }

    /// Reminders show even while Oatcake is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 520)
        } detail: {
            if showsList {
                HSplitView {
                    MeetingListView(folder: model.tree?.find(model.folder) ?? model.tree)
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
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
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
