// The menu bar item. While a call is being recorded it shows the running time, with Stop in its
// menu. Otherwise, with a calendar connected (and Settings › Calendar's switch on), it shows the time
// until your next call and lists what's coming up.

import AppKit
import OatcakeCore

@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    enum Content {
        /// `elapsed` is nil until audio arrives.
        case recording(title: String, elapsed: Double?)
        /// Timed events that haven't ended, soonest first.
        case upcoming([CalendarEvent])
    }

    var stop: () -> Void = {}
    var open: () -> Void = {}
    var record: () -> Void = {}
    var openEvent: (CalendarEvent) -> Void = { _ in }

    private var item: NSStatusItem?
    private var content: Content?
    private var symbol = ""
    private var listed: [CalendarEvent] = []

    func show(_ content: Content) {
        self.content = content
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            created.menu = menu
            created.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            created.button?.imagePosition = .imageLeading
            item = created
        }
        guard let button = item?.button else { return }
        let symbol: String, title: String, tip: String
        var red = false
        switch content {
        case .recording(let name, let elapsed):
            (symbol, title, tip, red) = ("record.circle.fill", elapsed.map { " " + clock($0) } ?? "", "Oatcake is recording “\(name)”", true)
        case .upcoming(let events):
            let now = Date()
            let label = nextCallLabel(events, now: now)
            let next = events.first { $0.startDate > now } ?? events.first
            (symbol, title, tip) = ("calendar", label.isEmpty ? "" : " " + label,
                                    next.map { "\($0.title) · \(hhmm($0.startDate))–\(hhmm($0.endDate))" } ?? "Nothing coming up on your calendar")
        }
        // Set only on a change: this runs twice a second during a recording.
        if button.title != title { button.title = title }
        if button.toolTip != tip { button.toolTip = tip }
        if self.symbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: red ? "Recording" : "Next call")?
                .withSymbolConfiguration(red ? .init(paletteColors: [.systemRed]) : .init(pointSize: 0, weight: .regular))
            image?.isTemplate = !red
            button.image = image
            self.symbol = symbol
        }
    }

    func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        content = nil
        symbol = ""
    }

    /// Built when it opens, so it lists what's coming up now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, tag: Int = 0) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }
        switch content {
        case .recording(let name, let elapsed):
            add("Recording “\(name)”\(elapsed.map { " · \(clock($0))" } ?? "")", nil)
            add("Stop Recording", #selector(stopRecording))
        case .upcoming(let events):
            let now = Date()
            let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
            listed = Array(events.filter { $0.startDate < endOfTomorrow }.prefix(6))
            if listed.isEmpty { add("Nothing else today or tomorrow", nil) }
            for (index, event) in listed.enumerated() {
                let when = event.startDate <= now ? "Now" : Calendar.current.isDate(event.startDate, inSameDayAs: now)
                    ? hhmm(event.startDate) : "\(shortWeekday(event.startDate)) \(hhmm(event.startDate))"
                add("\(when)   \(event.title)", #selector(openListed(_:)), tag: index)
            }
            menu.addItem(.separator())
            add("New Recording…", #selector(newRecording))
        case nil:
            break
        }
        menu.addItem(.separator())
        add("Open Oatcake", #selector(openApp))
        add("Quit Oatcake", #selector(quit))
    }

    @objc private func stopRecording() { stop() }
    @objc private func openApp() { open() }
    @objc private func newRecording() { record() }
    @objc private func openListed(_ sender: NSMenuItem) {
        if listed.indices.contains(sender.tag) { openEvent(listed[sender.tag]) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// "12m", "1h 5m" or "now" for the menu bar: the time until the next call starts. A call that's
/// under way shows "now" unless the next one is within a quarter of an hour. "" when nothing is
/// coming up in the next day.
func nextCallLabel(_ events: [CalendarEvent], now: Date) -> String {
    let next = events.first { $0.startDate > now }
    let minutesAway = next.map { Int(($0.startDate.timeIntervalSince(now) / 60).rounded(.up)) }
    if events.contains(where: { $0.startDate <= now && $0.endDate > now }), (minutesAway ?? .max) > 15 { return "now" }
    guard let minutesAway, minutesAway < 24 * 60 else { return "" }
    return minutesAway < 60 ? "\(minutesAway)m" : "\(minutesAway / 60)h\(minutesAway % 60 == 0 ? "" : " \(minutesAway % 60)m")"
}
