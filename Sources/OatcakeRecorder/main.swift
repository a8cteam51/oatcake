// Records a meeting as two tracks: the microphone (you) and everything the Mac
// plays (everyone else), captured with a Core Audio process tap.
//
// Usage: oatcake-recorder --out <dir>      record until SIGINT or SIGTERM
//        oatcake-recorder --list-inputs   print the input devices as JSON
// Writes 16 kHz mono PCM16 to <dir>/mic.pcm and <dir>/system.pcm, status.json
// once a second, and meta.json on stop. Reads <dir>/mic.json every second for the
// chosen input, so it can be changed mid-call.
//
// The system-audio tap is adapted from OpenWhispr's macos-audio-tap.swift
// (MIT, Copyright (c) 2024 OpenWhispr Team). See THIRD_PARTY_NOTICES.md.

import AVFoundation
import CoreAudio
import Foundation

let sampleRate = 16_000.0
let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

/// Converts incoming buffers to 16 kHz mono PCM16 and appends them to a file.
final class Track {
    let name: String
    private let handle: FileHandle
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private(set) var samplesWritten = 0
    private(set) var firstBufferAt: Date?
    private var _lastBufferAt: Date?
    private var gapPending = false
    private var peak: Float = 0

    init(name: String, path: String) throws {
        self.name = name
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func append(_ source: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
            converter?.downmix = true  // multi-mic arrays: mix every channel into the mono track
        }
        guard let converter else { return }

        let capacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * sampleRate / max(source.format.sampleRate, 1))) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, status == .haveData || status == .inputRanDry,
              let samples = output.int16ChannelData?[0] else { return }

        let count = Int(output.frameLength)
        var bufferPeak: Int16 = 0
        for i in 0..<count {
            let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
            if v > bufferPeak { bufferPeak = v }
        }

        lock.lock()
        let now = Date()
        if let first = firstBufferAt {
            // After the source changed, fill the time it took with silence so this track
            // stays lined up with the other one.
            let expected = Int(now.timeIntervalSince(first) * sampleRate) - count
            if gapPending, expected > samplesWritten {
                handle.write(Data(count: (expected - samplesWritten) * 2))
                samplesWritten = expected
            }
        } else {
            firstBufferAt = now
        }
        gapPending = false
        _lastBufferAt = now
        handle.write(Data(bytes: samples, count: count * 2))
        samplesWritten += count
        peak = max(peak, Float(bufferPeak) / Float(Int16.max))
        lock.unlock()
    }

    var lastBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastBufferAt
    }

    /// Seconds of audio written so far.
    var elapsed: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samplesWritten) / sampleRate
    }

    /// The source is changing: pad with silence before the next buffer.
    func markGap() {
        lock.lock()
        gapPending = true
        lock.unlock()
    }

    /// Peak level (0–1) since the last call.
    func takePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }

    func close() {
        lock.lock()
        try? handle.close()
        lock.unlock()
    }
}

/// Everything the Mac plays, via a global process tap on an aggregate device.
final class SystemAudioCapture {
    private let track: Track
    private var tapID = AudioObjectID(0)
    private var deviceID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "oatcake-recorder.system")

    init(track: Track) { self.track = track }

    func start() throws {
        let description = CATapDescription()
        description.name = "oatcake-recorder"
        description.uuid = UUID()
        description.processes = []  // exclusive + empty = every process
        description.isExclusive = true
        description.isMono = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }, "read tap UID")
        guard let tapUID = uid?.takeRetainedValue() as String? else { throw RecorderError("tap has no UID") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "oatcake-recorder",
            kAudioAggregateDeviceUIDKey: "oatcake-recorder.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioTapPropertyFormat
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError("unusable tap format") }

        let track = self.track
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: UnsafeMutablePointer(mutating: input), deallocator: nil)
            else { return }
            track.append(buffer)
        }, "create IO proc")

        try check(AudioDeviceStart(deviceID, procID), "start aggregate device")
    }

    func stop() {
        if deviceID != 0 { AudioDeviceStop(deviceID, procID) }
        if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
        if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = 0
        tapID = 0
    }
}

// MARK: - Input devices

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var where_ = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &where_, 0, nil, &size, $0) }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

/// Every device with an input stream, in the order macOS lists them.
func inputDevices() -> [InputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &devices, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("oatcake-recorder"),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

func defaultInputDevice() -> AudioDeviceID {
    var where_ = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &id)
    return id
}

/// The format the device delivers its first input stream in, or nil if it has none right now.
func inputFormat(_ id: AudioDeviceID) -> AVAudioFormat? {
    var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
    var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &streams, 0, nil, &size, &ids) == noErr, let stream = ids.first else { return nil }
    var virtual = address(kAudioStreamPropertyVirtualFormat)
    var asbd = AudioStreamBasicDescription()
    size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &virtual, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
    // AVAudioFormat needs a layout for more than two channels; they're mixed down to mono later.
    let layout = asbd.mChannelsPerFrame > 2
        ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
        : nil
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
}

/// The chosen input, or the Mac's current input when none is chosen or the chosen one is
/// unplugged. check() runs every second and restarts capture whenever the device it should be
/// on changes, its format changes, or audio stops arriving, so the recording carries on through
/// headphones connecting, a mic being unplugged, or a change of input in System Settings.
///
/// Reads the device directly through Core Audio rather than AVAudioEngine: AVAudioEngine throws
/// Objective-C exceptions (which Swift can't catch) when a device changes format mid-setup, and
/// one of those crashed a recording on 2026-11-05 as Bluetooth headphones switched modes.
final class MicCapture {
    private let track: Track
    private let queue = DispatchQueue(label: "oatcake-recorder.mic")
    private var deviceID = AudioDeviceID(0)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var startedAt = Date.distantPast
    /// Device UID from mic.json; nil follows the Mac's input.
    var wanted: String?
    private(set) var device: InputDevice?
    private(set) var switches: [[String: Any]] = []

    init(track: Track) { self.track = track }

    func check() {
        let devices = inputDevices()
        let fallback = defaultInputDevice()
        let target = devices.first { $0.uid == wanted } ?? devices.first { $0.id == fallback }
        // Some devices (Bluetooth especially) take a moment to deliver their first audio.
        let lastSign = max(startedAt.addingTimeInterval(3), track.lastBufferAt ?? .distantPast)
        let stalled = procID != nil && Date().timeIntervalSince(lastSign) > 2
        let reformatted = procID != nil && inputFormat(deviceID) != format
        if procID == nil || stalled || reformatted || target?.uid != device?.uid { restart(on: target) }
    }

    private func restart(on target: InputDevice?) {
        stop()
        guard let target, let format = inputFormat(target.id) else { return }  // the next check tries again
        let track = self.track
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, target.id, queue) { _, input, _, _, _ in
            // One buffer per input stream; record the first.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list, deallocator: nil) else { return }
            track.append(buffer)
        }
        guard created == noErr, let proc else { return }
        track.markGap()
        guard AudioDeviceStart(target.id, proc) == noErr else {
            AudioDeviceDestroyIOProcID(target.id, proc)
            return
        }
        deviceID = target.id
        procID = proc
        self.format = format
        device = target
        startedAt = Date()
        switches.append(["at": track.elapsed, "uid": target.uid, "name": target.name])
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = 0
        format = nil
        device = nil
    }
}

struct RecorderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw RecorderError("\(what) failed (OSStatus \(status))") }
}

func writeJSON(_ object: [String: Any], to path: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func requestMicAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
        done.wait()
        return granted
    default: return false
    }
}

// MARK: - Main

let args = CommandLine.arguments
if args.contains("--list-inputs") {
    let current = defaultInputDevice()
    let list = inputDevices().map { ["uid": $0.uid, "name": $0.name, "isDefault": $0.id == current] as [String: Any] }
    let data = try! JSONSerialization.data(withJSONObject: list)
    FileHandle.standardOutput.write(data)
    exit(0)
}
guard let outFlag = args.firstIndex(of: "--out"), outFlag + 1 < args.count else {
    FileHandle.standardError.write("usage: oatcake-recorder --out <dir> | --list-inputs\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[outFlag + 1]
let statusPath = "\(outDir)/status.json"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try? "\(getpid())".write(toFile: "\(outDir)/recorder.pid", atomically: true, encoding: .utf8)

func fail(_ message: String) -> Never {
    writeJSON(["state": "error", "error": message], to: statusPath)
    exit(1)
}

let startedAt = Date()
let micTrack: Track
let systemTrack: Track
do {
    micTrack = try Track(name: "mic", path: "\(outDir)/mic.pcm")
    systemTrack = try Track(name: "system", path: "\(outDir)/system.pcm")
} catch {
    fail("cannot create audio files in \(outDir): \(error)")
}

guard requestMicAccess() else {
    fail("Microphone access is off. Turn on Oatcake in System Settings › Privacy & Security › Microphone.")
}

/// The app writes {"uid": "<device UID>"} to mic.json to choose an input (null = the Mac's).
func wantedMic() -> String? {
    guard let data = FileManager.default.contents(atPath: "\(outDir)/mic.json"),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["uid"] as? String
}

let system = SystemAudioCapture(track: systemTrack)
let mic = MicCapture(track: micTrack)
do {
    try system.start()
} catch {
    fail("\(error)")
}
mic.wanted = wantedMic()
mic.check()

func offset(_ track: Track) -> Double {
    track.firstBufferAt.map { $0.timeIntervalSince(startedAt) } ?? 0
}

let iso = ISO8601DateFormatter()
let statusTimer = DispatchSource.makeTimerSource(queue: .main)
statusTimer.schedule(deadline: .now() + 1, repeating: 1)
statusTimer.setEventHandler {
    mic.wanted = wantedMic()
    mic.check()
    writeJSON([
        "state": "recording",
        "startedAt": iso.string(from: startedAt),
        "elapsed": Date().timeIntervalSince(startedAt),
        "micLevel": micTrack.takePeak(),
        "systemLevel": systemTrack.takePeak(),
        "micSeconds": Double(micTrack.samplesWritten) / sampleRate,
        "systemSeconds": Double(systemTrack.samplesWritten) / sampleRate,
        "micDevice": mic.device.map { ["uid": $0.uid, "name": $0.name] } as Any,
    ], to: statusPath)
}
statusTimer.resume()

func finish() -> Never {
    statusTimer.cancel()
    mic.stop()
    system.stop()
    micTrack.close()
    systemTrack.close()
    let meta: [String: Any] = [
        "startedAt": iso.string(from: startedAt),
        "endedAt": iso.string(from: Date()),
        "sampleRate": Int(sampleRate),
        // Seconds from startedAt to each track's first sample, for aligning the two.
        "micOffset": offset(micTrack),
        "systemOffset": offset(systemTrack),
        // Which input was recorded when, in seconds into the mic track.
        "micDevices": mic.switches,
    ]
    writeJSON(meta, to: "\(outDir)/meta.json")
    writeJSON(["state": "stopped"], to: statusPath)
    try? FileManager.default.removeItem(atPath: "\(outDir)/recorder.pid")
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { finish() }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
