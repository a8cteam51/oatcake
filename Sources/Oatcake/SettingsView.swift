import OatcakeCore
import SwiftUI
import UserNotifications

/// The Settings window, in panes. Every change is saved as it's made; there's no Save button.
struct SettingsView: View {
    @Environment(AppModel.self) var model
    @ViewState var devices: [InputDevice]?
    @ViewState var jargon = ""
    @ViewState var ignoredEvents = ""
    @ViewState var calendarEditor: CalendarSettingsEdit?
    /// Which reasoning switches the model just chosen changed, said under that model in the list.
    @ViewState var reasoningNote: String?
    /// macOS says notifications are turned off for Oatcake: reminders and call notices can't show.
    @ViewState private var notificationsOff = false
    @AppStorage(SettingsPane.key) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Form { general }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsPane.general)
            Form { calendar }.formStyle(.grouped).tabItem { Label("Calendars", systemImage: "calendar") }.tag(SettingsPane.calendar)
            Form { PeopleSection() }.formStyle(.grouped).tabItem { Label("People", systemImage: "person.2") }.tag(SettingsPane.people)
            Form { transcription; llmSection }.formStyle(.grouped).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsPane.models)
            Form { jargonSection; outputSections }.formStyle(.grouped).tabItem { Label("Summaries", systemImage: "text.alignleft") }.tag(SettingsPane.summaries)
            Form { storage; mcp }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "folder") }.tag(SettingsPane.storage)
            Form { UpdatesSection() }.formStyle(.grouped).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsPane.updates)
        }
        .frame(width: 620, height: 600)
        .sheet(item: $calendarEditor) { editor in
            if editor.fromThisMac {
                MacCalendarPicker(calendar: model.calendar)
            } else {
                CalendarEditor(calendar: model.calendar, existing: editor.existing)
            }
        }
        // Something that went wrong while this window is in front (a setting that couldn't be saved)
        // is said here too: the main window's own note is behind this one, or closed.
        .overlay(alignment: .bottom) {
            if let text = model.toastText, model.toastIsError { ToastView(text: text, isError: true) { model.dismissToast() } }
        }
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
        // Looked at again whenever a pane is shown: it may have been changed in System Settings meanwhile.
        .task(id: pane) { notificationsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
        .onAppear {
            // Speech to text was once a pane of its own, now part of Models.
            if UserDefaults.standard.string(forKey: SettingsPane.key) == "transcription" { pane = .models }
            jargon = model.config.jargon.joined(separator: ", ")
            ignoredEvents = model.config.ignoredEvents.joined(separator: ", ")
            // The Electron version's names for the two transcription choices read as the new ones.
            let key = SpeechModels.asrChoice(model.config.asrModel).key
            if key != model.config.asrModel { model.saveConfig(with(model.config) { $0.asrModel = key }) }
        }
    }

    /// Shown under a switch that works by notification, when macOS won't show Oatcake's.
    @ViewBuilder var notificationsHint: some View {
        if notificationsOff {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Notifications are turned off for Oatcake in System Settings, so this can’t be shown.").settingsHint(.amber)
                Button("Open notification settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
    }

    func bind<T>(_ path: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: path] }, set: { value in model.saveConfig(with(model.config) { $0[keyPath: path] = value }) })
    }

    func bindLlm<T>(_ path: WritableKeyPath<LlmConfig, T>) -> Binding<T> {
        let llm: WritableKeyPath<Config, LlmConfig> = \.llm
        return bind(llm.appending(path: path))
    }
}

func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

extension Text {
    func settingsHint(_ color: Color = .secondary) -> some View {
        font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
