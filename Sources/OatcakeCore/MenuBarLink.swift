import Foundation

// What passes between Oatcake and the helper that draws its menu bar item (Oatcake run again with
// --menu-bar): what to show goes one way and what was chosen from the menu comes back, each as a
// line of JSON.

/// What the menu bar item shows.
public enum MenuBarContent: Codable, Equatable, Sendable {
    /// `elapsed` is nil until audio arrives.
    case recording(title: String, elapsed: Double?)
    /// Timed events that haven't ended, soonest first.
    case upcoming([CalendarEvent])
}

/// What was chosen from the item's menu.
public enum MenuBarAction: Codable, Equatable, Sendable {
    case stop
    case open
    case record
    case openEvent(CalendarEvent)
    case quit
}

public enum MenuBarLink {
    /// The flag Oatcake's program is run with to be the helper.
    public static let flag = "--menu-bar"

    /// One line, with its newline: JSON never has a newline of its own outside a string, where it's escaped.
    public static func line<T: Encodable>(_ value: T) -> Data {
        ((try? JSONEncoder().encode(value)) ?? Data()) + Data("\n".utf8)
    }

    /// nil for a line that isn't one of these (a stray line of logging, say).
    public static func read<T: Decodable>(_ type: T.Type, _ line: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }
}

/// Lines out of the bytes a pipe delivers, which arrive in pieces of any size.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    /// The complete lines now in hand; the rest waits for more.
    public mutating func add(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
