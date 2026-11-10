// Dates, times and people, formatted the way the design shows them.

import OatcakeCore
import SwiftUI

private let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

func ordinal(_ d: Int) -> String {
    let suffix = (11...13).contains(d % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][d % 10] ?? "th"
    return "\(d)\(suffix)"
}

private var cal: Calendar { gregorian }

/// "October 29th, 2026"
func longDate(_ d: Date) -> String { "\(months[cal.component(.month, from: d) - 1]) \(ordinal(cal.component(.day, from: d))), \(cal.component(.year, from: d))" }
/// "October 29th"
func shortDate(_ d: Date) -> String { "\(months[cal.component(.month, from: d) - 1]) \(ordinal(cal.component(.day, from: d)))" }
/// "Thursday"
func weekday(_ d: Date) -> String { weekdays[cal.component(.weekday, from: d) - 1] }
/// "Thu"
func shortWeekday(_ d: Date) -> String { String(weekday(d).prefix(3)) }
/// "Oct"
func shortMonth(_ d: Date) -> String { String(months[cal.component(.month, from: d) - 1].prefix(3)) }
/// "16:30"
func hhmm(_ d: Date) -> String { String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d)) }

/// "32 min", or "under a minute".
func minutes(_ seconds: Double) -> String { seconds < 60 ? "under a minute" : "\(Int((seconds / 60).rounded())) min" }

/// The meeting's folder path for display: "Team 51 › Leads sync". "" is the top level.
func folderPath(_ rel: String) -> String { rel.isEmpty ? "Meetings" : rel.split(separator: "/").joined(separator: " › ") }
func baseName(_ rel: String) -> String { rel.split(separator: "/").last.map(String.init) ?? rel }
func parentOf(_ rel: String) -> String { rel.split(separator: "/").dropLast().joined(separator: "/") }

/// The folder's name (or whole path) says the same as the title, e.g. "Team 51/Leads sync" for "Team 51 – Leads sync".
func sameAsFolder(_ title: String, _ folder: String) -> Bool {
    !folder.isEmpty && !loose(title).isEmpty && (loose(title) == loose(baseName(folder)) || loose(title) == loose(folder))
}
/// The path above a title, without its last part when that only repeats the title.
func pathAbove(_ folder: String, _ title: String) -> String { folderPath(sameAsFolder(title, folder) ? parentOf(folder) : folder) }

/// Is this owner you? "Sam" counts for "Sam Lee".
func isMe(_ owner: String?, _ myName: String) -> Bool {
    guard let owner = owner?.trimmed.lowercased(), !owner.isEmpty, !myName.isEmpty else { return false }
    return [myName.lowercased(), (myName.split(separator: " ").first.map(String.init) ?? myName).lowercased()].contains(owner)
}
/// An owner as shown: "You" for you.
func ownerLabel(_ owner: String, _ myName: String) -> String { isMe(owner, myName) ? "You" : owner }

/// When a meeting happened: meeting.json, or the "2026-10-02 1400 Title" folder name.
func meetingDate(_ node: TreeNode) -> Date? {
    if let d = node.startedAt { return d }
    let digits = node.name.prefix(15)
    guard digits.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}$"#, options: .regularExpression) != nil else { return nil }
    let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len)) ?? 0 }
    return cal.date(from: DateComponents(year: n(0, 4), month: n(5, 2), day: n(8, 2), hour: n(11, 2), minute: n(13, 2)))
}

/// The title to show: meeting.json's, or the folder name without its date.
func meetingTitle(_ node: TreeNode) -> String {
    if let t = node.title, !t.isEmpty { return t }
    return node.name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, with: "", options: .regularExpression)
}

private func newestFirst(_ a: TreeNode, _ b: TreeNode) -> Bool {
    let da = meetingDate(a) ?? .distantPast, db = meetingDate(b) ?? .distantPast
    return da != db ? da > db : a.name > b.name
}

/// What the middle column lists: a folder's own meetings, or every meeting for the top level.
func listedIn(_ folder: TreeNode?) -> [TreeNode] {
    guard let folder else { return [] }
    return (folder.path.isEmpty ? folder.allMeetings : folder.meetings).sorted(by: newestFirst)
}

// MARK: - People

/// Labels that aren't a person: their avatars are grey.
private let notAPerson = #"^(Voice \d+|Several people|Microphone|System audio|Call audio|Unknown)$"#
private let hues: [Double] = [265, 25, 160, 330, 200, 60, 295, 130, 230, 0, 95, 180]
private let colorsKey = "personColors"

/**
 * Each person keeps one colour everywhere and for good: the first time a name is seen it takes the
 * palette's least-used hue (in the order above, which spreads early picks around the wheel), and that
 * choice is remembered. Keyed by first name, so "Alex" and "Alex Kim" match.
 */
private func hueFor(_ name: String, remember: Bool) -> Double {
    var all = (UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int]) ?? [:]
    let key = (name.trimmed.split(separator: " ").first.map(String.init) ?? name).lowercased()
    if let i = all[key], hues.indices.contains(i) { return hues[i] }
    let uses = hues.indices.map { i in all.values.filter { $0 == i }.count }
    let index = uses.firstIndex(of: uses.min()!)!
    // A name typed but not yet saved (in review) gets a colour without claiming one.
    if remember {
        all[key] = index
        UserDefaults.standard.set(all, forKey: colorsKey)
    }
    return hues[index]
}

struct Person {
    var initial: String
    var color: Color
    var isPerson: Bool
}

/// A person's avatar colour and initial: the same colour on every screen.
func person(_ name: String, remember: Bool = true) -> Person {
    let clean = name.replacingOccurrences(of: "^Voice ", with: "", options: .regularExpression)
    let initial = clean.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    if name.trimmed.isEmpty || name.range(of: notAPerson, options: .regularExpression) != nil {
        return Person(initial: name.hasPrefix("Voice") ? String(clean.prefix(1)) : initial, color: Color(nsColor: .systemGray), isPerson: false)
    }
    return Person(initial: initial, color: oklch(0.55, 0.15, hueFor(name, remember: remember)), isPerson: true)
}

/// The design's oklch(L C h) colours, in sRGB.
func oklch(_ l: Double, _ c: Double, _ h: Double) -> Color {
    let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
    let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
    let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
    func gamma(_ x: Double) -> Double {
        let v = max(0, min(1, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    return Color(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(bl))
}
