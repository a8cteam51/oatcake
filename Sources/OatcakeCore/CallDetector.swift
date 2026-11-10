// Notices a call without listening to it: Core Audio says which processes have a microphone open,
// and a calling app or a browser among them means you're probably on a call. Oatcake uses that to
// offer to record, and to know when a call it's recording has ended.

import CoreAudio
import Foundation

public enum CallDetector {
    /// Calling apps and browsers, by the start of their bundle IDs (their helper processes included).
    private static let callingApps: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.avconferenced", "FaceTime"), ("com.apple.facetime", "FaceTime"), ("com.hnc.discord", "Discord"),
        ("net.whatsapp.whatsapp", "WhatsApp"), ("com.cisco.webexmeetingsapp", "Webex"), ("cisco-systems.spark", "Webex"),
        ("com.skype.skype", "Skype"), ("org.whispersystems.signal-desktop", "Signal"), ("ru.keepcoder.telegram", "Telegram"),
        ("app.tuple.app", "Tuple"),
        ("com.google.chrome", "Google Chrome"), ("org.chromium.chromium", "Chromium"), ("com.apple.webkit", "Safari"),
        ("com.apple.safari", "Safari"), ("org.mozilla.firefox", "Firefox"), ("company.thebrowser.browser", "Arc"),
        ("company.thebrowser.dia", "Dia"), ("com.microsoft.edgemac", "Microsoft Edge"), ("com.brave.browser", "Brave"),
        ("com.vivaldi.vivaldi", "Vivaldi"), ("com.operasoftware.opera", "Opera"),
    ]

    /// The calling app a bundle ID belongs to, if it is one.
    static func callingApp(_ bundleID: String) -> String? {
        let id = bundleID.lowercased()
        return callingApps.first { id == $0.prefix || id.hasPrefix($0.prefix + ".") }?.name
    }

    /// The calling apps with a microphone open right now, e.g. ["Google Chrome"]. Empty when there are none.
    public static func appsOnCall() -> [String] {
        // For trying this without a call: OATCAKE_CALL_APPS names a file listing the apps to report, one per line.
        if let file = ProcessInfo.processInfo.environment["OATCAKE_CALL_APPS"] {
            return readText(URL(fileURLWithPath: file)).components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
        }
        var names: [String] = []
        for process in processes() where (number(process, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
            if let name = callingApp(bundleID(process)), !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}
