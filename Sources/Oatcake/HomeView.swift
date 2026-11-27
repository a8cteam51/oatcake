import AppKit
import OatcakeCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // No record button of its own: the sidebar’s Record a call (or Return to the call) is beside it.
                Text("Home").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                upcoming
                if model.config.todosEnabled { TodosView(homePreview: true) }
            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                heading("Upcoming")
                Spacer()
                if model.calendar.hasCalendars {
                    Button { model.calendar.refresh(force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: model.calendar.fetching && !reduceMotion)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh calendars")
                    .help("Refresh calendars (⌘R)")
                    .disabled(model.calendar.fetching)
                }
            }
            if model.calendar.hasCalendars {
                let now = model.calendar.now
                let events = upcomingCalls(model.calendar.events, at: now)
                let next = events.first { $0.startDate > now }
                UpcomingNote(empty: events.isEmpty)
                if !events.isEmpty {
                    // The sidebar's rows, with room beside them to join the call under way or the next one.
                    rows {
                        ForEach(events) { event in
                            if event.id != events.first?.id { Divider() }
                            HStack(spacing: 12) {
                                UpcomingRow(event: event, next: next, now: now)
                                if event.startDate <= now || event.id == next?.id, let link = event.callLink, let url = URL(string: link) {
                                    Button { NSWorkspace.shared.open(url) } label: {
                                        Label("Join the call", systemImage: "video")
                                    }
                                    .accessibilityLabel("Join the call: \(event.title)")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            } else {
                Text("Connect your calendar to see what’s coming up.").foregroundStyle(.secondary)
                Button("Connect calendar") { showSettingsPane(.calendar, openSettings) }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line).allowsHitTesting(false) }
    }
}
