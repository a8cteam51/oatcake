import Foundation

public let sampleRate = 16_000

/// Reads a raw 16 kHz mono PCM16 file into floats in [-1, 1].
func readPcm(_ url: URL) -> [Float] {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
    return data.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
    }
}

/// The samples between two times in seconds, clamped to the track.
func slice(_ samples: [Float], _ start: Double, _ end: Double) -> ArraySlice<Float> {
    let from = max(0, min(samples.count, Int((start * Double(sampleRate)).rounded(.down))))
    let to = max(from, min(samples.count, Int((end * Double(sampleRate)).rounded(.up))))
    return samples[from..<to]
}

/// Writes floats as a 16 kHz mono PCM16 WAV file (the review screen's clips).
func writeWav(_ url: URL, _ samples: ArraySlice<Float>) throws {
    var data = Data(capacity: 44 + samples.count * 2)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1) // PCM
    u16(1) // mono
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))
    u16(2)
    u16(16)
    data.append(contentsOf: Array("data".utf8))
    u32(UInt32(samples.count * 2))
    for s in samples {
        u16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32767).rounded())))
    }
    try data.write(to: url)
}
