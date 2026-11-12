// The menu bar item. While a call is being recorded it shows the running time, with Stop in its
// menu. Otherwise, with a calendar connected (and Settings › Calendar's switch on), it shows the time
// until your next call and lists what's coming up.
//
// It's drawn by a helper: Oatcake's own program run a second time (with --menu-bar) as a
// menu-bar-only app. macOS doesn't draw a Dock app's menu bar menu over another app's full-screen
// Space: the item highlights and nothing appears, however the menu is opened. A menu-bar-only
// app's menu is drawn there. Oatcake tells the helper what to show, and the helper tells Oatcake
// what was chosen (MenuBarLink).

import AppKit
import OatcakeCore

/// Oatcake's side: starts the helper when there's something to show, and keeps it told.
@MainActor
final class MenuBarItem {
    typealias Content = MenuBarContent

    var stop: () -> Void = {}
    var open: () -> Void = {}
    var record: () -> Void = {}
    var openEvent: (CalendarEvent) -> Void = { _ in }

    private var helper: Process?
    private var toHelper: FileHandle?
    private var lastSent: Data?
    private var lastStart = Date.distantPast

    func show(_ content: Content) {
        let line = MenuBarLink.line(content)
        // Told only of a change: the helper keeps the time until the next call up to date itself.
        if helper != nil, line == lastSent { return }
        if helper == nil {
            // A helper that keeps failing isn't started over and over.
            guard Date().timeIntervalSince(lastStart) > 5 else { return }
            start()
        }
        do {
            try toHelper?.write(contentsOf: line)
            lastSent = line
        } catch {
            // It has gone: the next change starts another.
            stopHelper()
        }
    }

    func hide() { stopHelper() }

    private func start() {
        lastStart = Date()
        // Writing to a helper that has just died is an error to handle, not a reason to be stopped.
        signal(SIGPIPE, SIG_IGN)
        guard let program = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = program
        process.arguments = [MenuBarLink.flag]
        process.environment = ShellEnvironment.childEnvironment()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // One pipe's handler runs one call at a time, so the buffer needs no lock.
        final class Lines: @unchecked Sendable { var buffer = LineBuffer() }
        let lines = Lines()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in lines.buffer.add(handle.availableData) {
                guard let action = MenuBarLink.read(MenuBarAction.self, line) else { continue }
                Task { @MainActor in self?.chosen(action) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                // Unless it was stopped on purpose and another has started since.
                if self?.helper === ended { self?.stopHelper() }
            }
        }
        do { try process.run() } catch { return }
        helper = process
        toHelper = input.fileHandleForWriting
        lastSent = nil
    }

    private func stopHelper() {
        // It leaves when its input closes; told to as well, in case it's busy.
        try? toHelper?.close()
        if helper?.isRunning == true { helper?.terminate() }
        helper = nil
        toHelper = nil
        lastSent = nil
    }

    private func chosen(_ action: MenuBarAction) {
        switch action {
        case .stop: stop()
        case .open: open()
        case .record: record()
        case .openEvent(let event): openEvent(event)
        case .quit: NSApp.terminate(nil)
        }
    }
}

/// The helper: a menu-bar-only run of Oatcake's program that owns the menu bar item. It shows what
/// it's told on its input, and writes what's chosen from the menu on its output. It leaves when its
/// input closes, which is when Oatcake hides the item or quits.
@MainActor
enum MenuBarHelper {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let item = StatusItem()
        item.send = { action in FileHandle.standardOutput.write(MenuBarLink.line(action)) }
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let content = MenuBarLink.read(MenuBarContent.self, line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { item.show(content) } }
            }
            exit(0)
        }
        // The time until the next call counts down without Oatcake having to say so.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in MainActor.assumeIsolated { item.refresh() } }
        app.run()
        exit(0)
    }
}

/// The item itself, in the helper.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    typealias Content = MenuBarContent

    var send: (MenuBarAction) -> Void = { _ in }

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
            (symbol, title, tip) = ("oatcake", label.isEmpty ? "" : " " + label,
                                    next.map { "\($0.title) · \(hhmm($0.startDate))–\(hhmm($0.endDate))" } ?? "Nothing coming up on your calendar")
        }
        // Set only on a change: this runs twice a second during a recording.
        if button.title != title { button.title = title }
        if button.toolTip != tip { button.toolTip = tip }
        if self.symbol != symbol {
            // Recording: a red dot. Otherwise Oatcake's own oatcake, beside the time until the next call.
            let recordingDot = NSImage(systemSymbolName: symbol, accessibilityDescription: "Recording")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            recordingDot?.isTemplate = false
            button.image = red ? recordingDot : oatcakeGlyph
            button.setAccessibilityLabel(red ? "Oatcake, recording" : "Oatcake, next call")
            self.symbol = symbol
        }
    }

    /// Shows the same again, for what depends on the time.
    func refresh() {
        if let content { show(content) }
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

    @objc private func stopRecording() { send(.stop) }
    @objc private func openApp() { bringOatcakeForward(); send(.open) }
    @objc private func newRecording() { bringOatcakeForward(); send(.record) }
    @objc private func openListed(_ sender: NSMenuItem) {
        guard listed.indices.contains(sender.tag) else { return }
        bringOatcakeForward()
        send(.openEvent(listed[sender.tag]))
    }
    @objc private func quit() { send(.quit) }

    /// The click was on the helper's menu, so it's the helper macOS will let bring an app forward:
    /// it passes that on to Oatcake, which then shows its window.
    private func bringOatcakeForward() {
        guard let oatcake = NSRunningApplication(processIdentifier: getppid()) else { return }
        NSApp.yieldActivation(to: oatcake)
        oatcake.activate(from: .current, options: [])
    }
}

/// The oatcake from Oatcake's icon, for the menu bar: its outline filled, with the waveform cut out of
/// it. A template image, so macOS draws it light or dark to suit the menu bar. The icon's eleven
/// bars are too fine at this size, so it has five of them, in the same rise and fall.
let oatcakeGlyph: NSImage = {
    // The icon's outline, every other point, around (0, 0) with a radius of 1.
    let outline = "0.995,0.001 0.958,0.101 0.976,0.208 0.929,0.303 0.899,0.402 0.856,0.496 0.797,0.581 0.729,0.659 0.662,0.739 0.574,0.794 0.491,0.856 0.405,0.916 0.299,0.928 0.207,0.985 0.099,0.969 -0.003,0.998 -0.106,0.982 -0.209,0.971 -0.307,0.938 -0.408,0.910 -0.494,0.852 -0.584,0.801 -0.669,0.741 -0.733,0.658 -0.811,0.588 -0.844,0.486 -0.913,0.406 -0.941,0.306 -0.965,0.205 -0.985,0.104 -0.992,0.001 -0.985,-0.102 -0.970,-0.205 -0.945,-0.305 -0.895,-0.396 -0.871,-0.500 -0.785,-0.568 -0.748,-0.671 -0.660,-0.729 -0.586,-0.802 -0.498,-0.857 -0.404,-0.901 -0.304,-0.927 -0.211,-0.980 -0.106,-0.980 -0.003,-0.986 0.101,-0.988 0.199,-0.946 0.307,-0.952 0.395,-0.893 0.492,-0.856 0.577,-0.797 0.662,-0.738 0.730,-0.659 0.804,-0.585 0.850,-0.492 0.900,-0.401 0.937,-0.305 0.957,-0.203 0.991,-0.104".split(separator: " ").map { pair -> NSPoint in
        let xy = pair.split(separator: ",").map { Double($0) ?? 0 }
        return NSPoint(x: xy[0], y: xy[1])
    }
    let bars: [CGFloat] = [3.8, 7.5, 9.5, 8.3, 3.1]
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
        let centre = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 8.5
        let cookie = NSBezierPath()
        for (i, p) in outline.enumerated() {
            let point = NSPoint(x: centre.x + p.x * radius, y: centre.y + p.y * radius)
            if i == 0 { cookie.move(to: point) } else { cookie.line(to: point) }
        }
        cookie.close()
        NSColor.black.setFill()
        cookie.fill()
        // The bars are cut out, not drawn.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let width: CGFloat = 1.7, gap: CGFloat = 1.1
        var x = centre.x - (CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap) / 2
        for height in bars {
            NSBezierPath(roundedRect: NSRect(x: x, y: centre.y - height / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
            x += width + gap
        }
        return true
    }
    image.isTemplate = true
    return image
}()

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
