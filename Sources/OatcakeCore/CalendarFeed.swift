// The calendar's private iCal address: fetched at most once an hour, its events from a day ago to
// two weeks ahead kept in calendar.json. Recurring events are expanded here (RFC 5545 RRULE,
// EXDATE, RDATE and moved or cancelled occurrences), in the event's own time zone.

import Foundation

public struct CalendarEvent: Codable, Identifiable, Equatable, Hashable, Sendable {
    public struct Attendee: Codable, Equatable, Hashable, Sendable {
        public var name: String?
        public var email: String
    }
    /// Unique per occurrence.
    public var id: String
    /// Shared by every occurrence of a recurring event.
    public var seriesId: String?
    public var title: String
    public var start: String
    public var end: String
    public var allDay: Bool
    public var attendees: [Attendee]
    public var meetUrl: String?

    public var startDate: Date { parseISO(start) ?? .distantPast }
    public var endDate: Date { parseISO(end) ?? .distantPast }
    /// The call link, if it's a real Meet, Zoom or Teams address (checked again: the cache may predate the check).
    public var callLink: String? { meetUrl.flatMap { callApp($0) != nil ? $0 : nil } }
}

public struct CalendarCache: Codable, Equatable, Sendable {
    /// Last fetch attempt, successful or not.
    public var checkedAt: String?
    /// Last successful fetch.
    public var updatedAt: String?
    public var error: String?
    public var events: [CalendarEvent] = []

    public static func load() -> CalendarCache { tryJSON(CalendarCache.self, Paths.calendar) ?? CalendarCache() }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        try writeAtomic(Paths.calendar, try encodeJSON(self))
    }

    /// Fresh for an hour; the refresh button fetches regardless.
    public func isStale(now: Date = Date()) -> Bool {
        guard let checked = parseISO(checkedAt) else { return true }
        return now.timeIntervalSince(checked) >= 3600
    }
}

/// Video-call services, by the exact host (or parent domain) their links use.
private let callHosts: [(name: String, pattern: String)] = [
    ("Google Meet", #"^meet\.google\.com$"#),
    ("Zoom", #"^(?:[a-z0-9-]+\.)*zoom\.us$"#),
    ("Microsoft Teams", #"^teams\.microsoft\.com$"#),
]

/// "Google Meet", "Zoom" or "Microsoft Teams" for a call link; nil for anything else.
public func callApp(_ url: String) -> String? {
    guard let components = URLComponents(string: url), components.scheme == "https", let host = components.host?.lowercased() else { return nil }
    return callHosts.first { host.range(of: $0.pattern, options: .regularExpression) != nil }?.name
}

/**
 * The first video-call link in an event's text. Hosts are checked whole, so a look-alike such as
 * "meet.google.com.example.net" or "evilzoom.us" is never offered as the call.
 */
public func findCallLink(_ text: String) -> String? {
    let regex = try! NSRegularExpression(pattern: #"https://[^\s<>"']+"#, options: .caseInsensitive)
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text) else { continue }
        let url = String(text[range]).replacingOccurrences(of: #"[),.;\]]+$"#, with: "", options: .regularExpression)
        if callApp(url) != nil { return url }
    }
    return nil
}

/**
 * Downloads the calendar and keeps the events from a day ago to two weeks ahead. A failed fetch keeps
 * the previous events and records the error. The address is a secret, so it never appears in errors.
 */
public func fetchCalendar(_ address: String) async -> CalendarCache {
    let previous = CalendarCache.load()
    let checkedAt = isoString(Date())
    let https = address.trimmed.replacingOccurrences(of: "^webcal:", with: "https:", options: [.regularExpression, .caseInsensitive])
    do {
        guard let url = URL(string: https) else { throw OatcakeError("that isn't a web address") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OatcakeError("the calendar address returned \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))".trimmed)
        }
        let now = Date()
        let events = parseCalendar(String(decoding: data, as: UTF8.self), from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
        return CalendarCache(checkedAt: checkedAt, updatedAt: checkedAt, error: nil, events: events)
    } catch {
        let message = (error as? URLError)?.code == .timedOut ? "the calendar took too long to answer" : error.localizedDescription
        var cache = previous
        cache.checkedAt = checkedAt
        cache.error = "Couldn't update the calendar: \(message)"
        return cache
    }
}

// MARK: - iCalendar

/// One content line: NAME;PARAM=value:VALUE.
struct ICalProperty {
    var name: String
    var params: [String: String]
    var value: String
}

final class ICalComponent {
    let name: String
    var properties: [ICalProperty] = []
    var children: [ICalComponent] = []
    init(name: String) { self.name = name }

    func first(_ name: String) -> ICalProperty? { properties.first { $0.name == name } }
    func all(_ name: String) -> [ICalProperty] { properties.filter { $0.name == name } }
    func components(_ name: String) -> [ICalComponent] { children.filter { $0.name == name } }
}

func parseICal(_ text: String) -> ICalComponent {
    // Unfold: a line starting with a space or tab continues the one before.
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
        if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
            lines[lines.count - 1] += raw.dropFirst()
        } else if !raw.isEmpty {
            lines.append(raw)
        }
    }
    let root = ICalComponent(name: "ROOT")
    var stack = [root]
    for line in lines {
        guard let property = parseContentLine(line) else { continue }
        if property.name == "BEGIN" {
            let child = ICalComponent(name: property.value.uppercased())
            stack.last!.children.append(child)
            stack.append(child)
        } else if property.name == "END" {
            if stack.count > 1 { stack.removeLast() }
        } else {
            stack.last!.properties.append(property)
        }
    }
    return root.children.first { $0.name == "VCALENDAR" } ?? root
}

private func parseContentLine(_ line: String) -> ICalProperty? {
    // The value starts at the first colon outside a quoted parameter value.
    var inQuotes = false
    var colon: String.Index?
    for i in line.indices {
        let c = line[i]
        if c == "\"" { inQuotes.toggle() }
        if c == ":" && !inQuotes { colon = i; break }
    }
    guard let colon else { return nil }
    let head = line[..<colon]
    let value = String(line[line.index(after: colon)...])
    var parts: [String] = []
    var current = ""
    inQuotes = false
    for c in head {
        if c == "\"" { inQuotes.toggle(); continue }
        if c == ";" && !inQuotes { parts.append(current); current = ""; continue }
        current.append(c)
    }
    parts.append(current)
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
        guard let eq = p.firstIndex(of: "=") else { continue }
        params[p[..<eq].uppercased()] = String(p[p.index(after: eq)...])
    }
    return ICalProperty(name: parts[0].uppercased(), params: params, value: value)
}

/// TEXT values escape commas, semicolons, backslashes and newlines.
func unescapeText(_ value: String) -> String {
    var out = ""
    var escaping = false
    for c in value {
        if escaping {
            out.append(c == "n" || c == "N" ? "\n" : c)
            escaping = false
        } else if c == "\\" {
            escaping = true
        } else {
            out.append(c)
        }
    }
    return out
}

/// A DTSTART-style time: an instant, whether it's a whole day, and the zone its wall-clock time is in.
struct ICalTime {
    var date: Date
    var isDate: Bool
    var zone: TimeZone
}

func timeZone(_ tzid: String?, aliases: [String: TimeZone]) -> TimeZone {
    guard let tzid else { return .current }
    let clean = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: #"^/"#, with: "", options: .regularExpression)
    return TimeZone(identifier: clean) ?? aliases[tzid] ?? .current
}

/// Parses one date or date-time value ("20261105", "20261105T140000", "20261105T140000Z").
func parseICalTime(_ value: String, tzid: String?, valueType: String?, aliases: [String: TimeZone]) -> ICalTime? {
    let v = value.trimmed
    var calendar = Calendar(identifier: .gregorian)
    let digits = v.filter(\.isNumber)
    if valueType?.uppercased() == "DATE" || (v.count == 8 && digits.count == 8) {
        // Whole days have no zone: they're days in whichever zone you're in.
        calendar.timeZone = .current
        guard digits.count >= 8, let y = Int(digits.prefix(4)), let m = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.dropFirst(6).prefix(2)),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        return ICalTime(date: date, isDate: true, zone: .current)
    }
    guard digits.count >= 14 else { return nil }
    let utc = v.hasSuffix("Z")
    let zone = utc ? TimeZone(identifier: "UTC")! : timeZone(tzid, aliases: aliases)
    calendar.timeZone = zone
    let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len)) ?? 0 }
    guard let date = calendar.date(from: DateComponents(year: n(0, 4), month: n(4, 2), day: n(6, 2), hour: n(8, 2), minute: n(10, 2), second: n(12, 2))) else { return nil }
    return ICalTime(date: date, isDate: false, zone: zone)
}

/// "PT1H30M", "P1D", "-PT15M" → seconds.
func parseDuration(_ value: String) -> TimeInterval? {
    let regex = try! NSRegularExpression(pattern: #"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#)
    guard let g = firstMatch(regex, value.trimmed) else { return nil }
    let num = { (i: Int) in Double(g[i] ?? "") ?? 0 }
    let total = num(2) * 604_800 + num(3) * 86_400 + num(4) * 3600 + num(5) * 60 + num(6)
    return g[1] == "-" ? -total : total
}

struct ICalEvent {
    let component: ICalComponent
    let uid: String
    let start: ICalTime
    let duration: TimeInterval

    init?(_ component: ICalComponent, aliases: [String: TimeZone]) {
        guard let dtstart = component.first("DTSTART"),
              let start = parseICalTime(dtstart.value, tzid: dtstart.params["TZID"], valueType: dtstart.params["VALUE"], aliases: aliases) else { return nil }
        self.component = component
        uid = component.first("UID")?.value ?? UUID().uuidString
        self.start = start
        if let dtend = component.first("DTEND"),
           let end = parseICalTime(dtend.value, tzid: dtend.params["TZID"], valueType: dtend.params["VALUE"], aliases: aliases) {
            duration = end.date.timeIntervalSince(start.date)
        } else if let d = component.first("DURATION").flatMap({ parseDuration($0.value) }) {
            duration = d
        } else {
            duration = start.isDate ? 86_400 : 0
        }
    }

    var summary: String { component.first("SUMMARY").map { unescapeText($0.value) } ?? "" }
}

/// Expands an iCalendar feed into the occurrences that overlap [from, to).
public func parseCalendar(_ text: String, from: Date, to: Date) -> [CalendarEvent] {
    let calendar = parseICal(text)
    // VTIMEZONE blocks name zones; Outlook's own names ("GMT Standard Time") are matched through
    // the IANA location some feeds include alongside.
    var aliases: [String: TimeZone] = [:]
    for zone in calendar.components("VTIMEZONE") {
        guard let tzid = zone.first("TZID")?.value else { continue }
        if let location = zone.first("X-LIC-LOCATION")?.value, let tz = TimeZone(identifier: location) { aliases[tzid] = tz }
    }
    // A Google calendar named after its owner's address: used to drop events they declined.
    let owner = (calendar.first("X-WR-CALNAME")?.value ?? "").lowercased()

    var masters: [String: ICalEvent] = [:]
    // Moved, edited or cancelled occurrences of a recurring event come as separate entries with the
    // same UID, keyed here by the instant they replace (matching by instant works whatever time zone
    // either entry is written in).
    var replaced: [String: [Date: ICalComponent]] = [:]
    for component in calendar.components("VEVENT") {
        let uid = component.first("UID")?.value ?? ""
        if let rid = component.first("RECURRENCE-ID"),
           let instant = parseICalTime(rid.value, tzid: rid.params["TZID"], valueType: rid.params["VALUE"], aliases: aliases) {
            replaced[uid, default: [:]][instant.date] = component
        } else if let event = ICalEvent(component, aliases: aliases) {
            masters[uid] = event
        }
    }

    var events: [CalendarEvent] = []
    func add(_ event: ICalEvent, start: Date, end: Date, isDate: Bool, seriesId: String?) {
        guard end > from, start < to else { return }
        let c = event.component
        if (c.first("STATUS")?.value ?? "").uppercased() == "CANCELLED" { return }
        let attendees = c.all("ATTENDEE").map { p -> (email: String, name: String?, declined: Bool) in
            let email = p.value.replacingOccurrences(of: "^mailto:", with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
            let name = p.params["CN"].flatMap { $0.isEmpty ? nil : $0 }
            return (email, name, (p.params["PARTSTAT"] ?? "").uppercased() == "DECLINED")
        }
        if !owner.isEmpty, attendees.contains(where: { $0.email == owner && $0.declined }) { return }
        // Google's own conference field first, then wherever else a link was pasted.
        let links = [c.first("X-GOOGLE-CONFERENCE")?.value, c.first("LOCATION")?.value, c.first("DESCRIPTION")?.value]
            .compactMap { $0.map(unescapeText) }.joined(separator: " ")
        let title = event.summary
        events.append(CalendarEvent(
            id: "\(event.uid)@\(isoString(start))", seriesId: seriesId, title: title.isEmpty ? "Untitled event" : title,
            start: isoString(start), end: isoString(end), allDay: isDate,
            attendees: attendees.map { CalendarEvent.Attendee(name: $0.name == $0.email ? nil : $0.name, email: $0.email) },
            meetUrl: findCallLink(links)))
    }

    for (uid, event) in masters {
        func emit(_ instant: Date) {
            if let change = replaced[uid]?[instant], let changed = ICalEvent(change, aliases: aliases) {
                add(changed, start: changed.start.date, end: changed.start.date.addingTimeInterval(changed.duration), isDate: changed.start.isDate, seriesId: uid)
            } else {
                add(event, start: instant, end: instant.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: uid)
            }
        }
        let rdates = extraDates(event.component, "RDATE", aliases: aliases)
        guard let rule = event.component.first("RRULE").flatMap({ RecurrenceRule($0.value, aliases: aliases) }) else {
            if rdates.isEmpty {
                add(event, start: event.start.date, end: event.start.date.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: nil)
            } else {
                // RDATE without RRULE: DTSTART plus the listed dates.
                ([event.start.date] + rdates).forEach(emit)
            }
            continue
        }
        let excluded = Set(extraDates(event.component, "EXDATE", aliases: aliases))
        let instants = Set(rule.occurrences(start: event.start, until: to) + rdates.filter { $0 < to })
        for instant in instants.sorted() where !excluded.contains(instant) {
            emit(instant)
        }
    }
    // Moved occurrences whose series isn't in the feed stand alone.
    for (uid, byInstant) in replaced where masters[uid] == nil {
        for component in byInstant.values {
            if let event = ICalEvent(component, aliases: aliases) {
                add(event, start: event.start.date, end: event.start.date.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: nil)
            }
        }
    }
    return events.sorted { $0.start < $1.start }
}

private func extraDates(_ component: ICalComponent, _ name: String, aliases: [String: TimeZone]) -> [Date] {
    component.all(name).flatMap { p in
        p.value.split(separator: ",").compactMap { parseICalTime(String($0), tzid: p.params["TZID"], valueType: p.params["VALUE"], aliases: aliases)?.date }
    }
}

/// An RRULE, expanded period by period in the event's time zone, so a 10:00 meeting stays at 10:00 across a clock change.
struct RecurrenceRule {
    enum Frequency: String { case DAILY, WEEKLY, MONTHLY, YEARLY }
    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: Date?
    /// (ordinal or 0, weekday 1 = Sunday … 7 = Saturday)
    var byDay: [(Int, Int)] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var bySetPos: [Int] = []
    var weekStart = 2

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    init?(_ value: String, aliases: [String: TimeZone]) {
        var parts: [String: String] = [:]
        for piece in value.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        guard let freq = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        frequency = freq
        interval = max(1, Int(parts["INTERVAL"] ?? "") ?? 1)
        count = parts["COUNT"].flatMap { Int($0) }
        until = parts["UNTIL"].flatMap { parseICalTime($0, tzid: nil, valueType: nil, aliases: aliases)?.date }
        byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { item in
            let s = String(item).uppercased()
            guard let day = Self.weekdays[String(s.suffix(2))] else { return nil }
            return (Int(s.dropLast(2)) ?? 0, day)
        }
        byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
        bySetPos = (parts["BYSETPOS"] ?? "").split(separator: ",").compactMap { Int($0) }
        weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 2
    }

    /// Occurrence start instants from DTSTART up to (not including) `limit`. Weekly meetings that began
    /// years ago are a few hundred periods; the cap guards against odd rules.
    func occurrences(start: ICalTime, until limit: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.zone
        calendar.firstWeekday = weekStart
        let wall = calendar.dateComponents([.hour, .minute, .second], from: start.date)
        let startDay = calendar.dateComponents([.year, .month, .day, .weekday], from: start.date)
        var out: [Date] = []
        var emitted = 0

        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents(year: y, month: m, day: d, hour: wall.hour, minute: wall.minute, second: wall.second)
            c.timeZone = start.zone
            guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        func daysIn(_ y: Int, _ m: Int) -> Int {
            calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: y, month: m, day: 1))!)!.count
        }
        /// Days of a month matching BYDAY (with ordinals counted within the month) or BYMONTHDAY.
        func daysOfMonth(_ y: Int, _ m: Int) -> [Int] {
            let count = daysIn(y, m)
            if !byMonthDay.isEmpty {
                return byMonthDay.map { $0 > 0 ? $0 : count + 1 + $0 }.filter { (1...count).contains($0) }
            }
            if !byDay.isEmpty {
                var days: [Int] = []
                for (ordinal, weekday) in byDay {
                    let matching = (1...count).filter { d in
                        calendar.component(.weekday, from: calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!) == weekday
                    }
                    if ordinal == 0 { days += matching }
                    else if ordinal > 0, ordinal <= matching.count { days.append(matching[ordinal - 1]) }
                    else if ordinal < 0, -ordinal <= matching.count { days.append(matching[matching.count + ordinal]) }
                }
                return days
            }
            return [startDay.day!]
        }

        var period = 0
        while period < 20_000 {
            var candidates: [Date] = []
            switch frequency {
            case .DAILY:
                guard let day = calendar.date(byAdding: .day, value: period * interval, to: start.date) else { break }
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                let dayOK = byDay.isEmpty || byDay.contains { $0.1 == c.weekday }
                let monthOK = byMonth.isEmpty || byMonth.contains(c.month!)
                let monthDayOK = byMonthDay.isEmpty || byMonthDay.contains(c.day!)
                if dayOK && monthOK && monthDayOK, let d = at(c.year!, c.month!, c.day!) { candidates = [d] }
            case .WEEKLY:
                guard let anchor = calendar.date(byAdding: .weekOfYear, value: period * interval, to: start.date),
                      let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else { break }
                let weekdays = byDay.isEmpty ? [startDay.weekday!] : byDay.map(\.1)
                for offset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                    if weekdays.contains(c.weekday!), byMonth.isEmpty || byMonth.contains(c.month!), let d = at(c.year!, c.month!, c.day!) {
                        candidates.append(d)
                    }
                }
            case .MONTHLY:
                let total = (startDay.year! * 12 + startDay.month! - 1) + period * interval
                let (y, m) = (total / 12, total % 12 + 1)
                if byMonth.isEmpty || byMonth.contains(m) { candidates = daysOfMonth(y, m).compactMap { at(y, m, $0) } }
            case .YEARLY:
                let y = startDay.year! + period * interval
                for m in byMonth.isEmpty ? [startDay.month!] : byMonth { candidates += daysOfMonth(y, m).compactMap { at(y, m, $0) } }
            }
            candidates = Array(Set(candidates)).sorted()
            if !bySetPos.isEmpty {
                candidates = bySetPos.compactMap { pos in
                    let i = pos > 0 ? pos - 1 : candidates.count + pos
                    return candidates.indices.contains(i) ? candidates[i] : nil
                }.sorted()
            }
            for candidate in candidates where candidate >= start.date {
                if let until, candidate > until { return out }
                if let count, emitted >= count { return out }
                if candidate >= limit { return out }
                emitted += 1
                out.append(candidate)
            }
            // Past the window with nothing left to emit in it.
            if let first = candidates.first, first >= limit { return out }
            period += 1
        }
        return out
    }
}
