import AVFoundation
import Foundation

/// Turns the two call tracks into speaker-labelled chunks WITHOUT a diarisation
/// model: energy-based voice activity per track → speech segments → merged into
/// turns, cut at natural pauses, ≤ 2 minutes each. Each chunk is exported as a
/// small .m4a for transcription. Chunking also sidesteps the 25 MB upload cap.
enum CallSegmenter {

    enum Speaker: String { case me = "Du", other = "Gegenseite" }

    struct Segment {
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        let energy: Float
        var duration: TimeInterval { end - start }
    }

    struct Chunk {
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        let fileURL: URL
    }

    // Tunables (seconds / linear RMS).
    static let windowSeconds: TimeInterval   = 0.05
    static let closeGapSeconds: TimeInterval = 0.8     // silence that ends a segment
    static let minSegmentSeconds: TimeInterval = 0.4
    static let padSeconds: TimeInterval      = 0.2
    static let mergeGapSeconds: TimeInterval = 2.0     // same speaker, short gap → one chunk
    static let maxChunkSeconds: TimeInterval = 120

    // MARK: - Energy analysis

    /// RMS per 50 ms window, mono-mixed. nil if unreadable.
    static func energyProfile(url: URL) -> (rms: [Float], windowSeconds: TimeInterval)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let win = max(1, Int(fmt.sampleRate * windowSeconds))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(win * 64)) else { return nil }
        var rms: [Float] = []
        var acc: Float = 0; var count = 0
        while true {
            do { try file.read(into: buf) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            let channels = Int(fmt.channelCount)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += ch[c][i] }
                s /= Float(channels)
                acc += s * s; count += 1
                if count == win {
                    rms.append((acc / Float(count)).squareRoot()); acc = 0; count = 0
                }
            }
        }
        if count > 0 { rms.append((acc / Float(count)).squareRoot()) }
        return (rms, windowSeconds)
    }

    /// Speech segments from an energy profile. Threshold adapts to the track's
    /// noise floor (20th percentile) so a quiet headset and a loud room both work.
    static func segments(from rms: [Float], window: TimeInterval, speaker: Speaker) -> [Segment] {
        guard !rms.isEmpty else { return [] }
        let sorted = rms.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let threshold = max(floor * 3.5, 0.004)

        var out: [Segment] = []
        var startIdx: Int? = nil
        var lastActive = -1
        var energySum: Float = 0; var energyN = 0
        func close(at endIdx: Int) {
            guard let s = startIdx else { return }
            let start = max(0, Double(s) * window - padSeconds)
            let end = Double(endIdx + 1) * window + padSeconds
            if end - start >= minSegmentSeconds {
                out.append(Segment(speaker: speaker, start: start, end: end,
                                   energy: energyN > 0 ? energySum / Float(energyN) : 0))
            }
            startIdx = nil; energySum = 0; energyN = 0
        }
        let gapWindows = Int(closeGapSeconds / window)
        for (i, v) in rms.enumerated() {
            if v > threshold {
                if startIdx == nil { startIdx = i }
                lastActive = i; energySum += v; energyN += 1
            } else if startIdx != nil, i - lastActive > gapWindows {
                close(at: lastActive)
            }
        }
        if startIdx != nil { close(at: lastActive) }
        return out
    }

    /// Drops microphone segments that are really the far side leaking through
    /// the speakers (fully inside a louder system segment).
    static func removeEcho(mic: [Segment], system: [Segment]) -> [Segment] {
        mic.filter { m in
            !system.contains { s in
                s.start <= m.start + 0.1 && s.end >= m.end - 0.1 && s.energy > m.energy * 1.4
            }
        }
    }

    /// Merges consecutive same-speaker segments (short gaps) into chunk ranges,
    /// capped at `maxChunkSeconds`, ordered by time.
    static func chunkRanges(_ segments: [Segment]) -> [(speaker: Speaker, start: TimeInterval, end: TimeInterval)] {
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [(Speaker, TimeInterval, TimeInterval)] = []
        for seg in sorted {
            if let last = out.last, last.0 == seg.speaker,
               seg.start - last.2 <= mergeGapSeconds,
               seg.end - last.1 <= maxChunkSeconds {
                out[out.count - 1].2 = max(last.2, seg.end)
            } else {
                out.append((seg.speaker, seg.start, seg.end))
            }
        }
        return out.map { (speaker: $0.0, start: $0.1, end: $0.2) }
    }

    // MARK: - Export

    /// Writes the [start, end] range of `source` to a new .m4a next to it.
    static func export(source: URL, start: TimeInterval, end: TimeInterval, to url: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let fmt = inFile.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:       fmt.sampleRate,
            AVNumberOfChannelsKey: Int(fmt.channelCount),
            // Encoder-valid bitrate for the source's rate (16 kHz mono caps at 48 kbps,
            // 32 kHz+ allows 96; stereo 128 from 32 kHz) — see RecordingService.
            AVEncoderBitRateKey:   fmt.channelCount > 1
                ? (fmt.sampleRate >= 32_000 ? 128_000 : 64_000)
                : RecordingService.vpBitrate(forSampleRate: fmt.sampleRate)
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        let startFrame = AVAudioFramePosition(max(0, start) * fmt.sampleRate)
        let endFrame = min(inFile.length, AVAudioFramePosition(end * fmt.sampleRate))
        guard endFrame > startFrame else { return }
        inFile.framePosition = startFrame
        var remaining = AVAudioFrameCount(endFrame - startFrame)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768) else { return }
        while remaining > 0 {
            let n = min(remaining, buf.frameCapacity)
            try inFile.read(into: buf, frameCount: n)
            if buf.frameLength == 0 { break }
            try outFile.write(from: buf)
            remaining -= buf.frameLength
        }
    }

    /// Full pipeline for one call: analyse both tracks → chunks on disk.
    static func makeChunks(micURL: URL, systemURL: URL?, workDir: URL) -> [Chunk] {
        var segs: [Segment] = []
        var micSegs: [Segment] = []
        if let p = energyProfile(url: micURL) {
            micSegs = segments(from: p.rms, window: p.windowSeconds, speaker: .me)
        }
        var sysSegs: [Segment] = []
        if let systemURL, FileManager.default.fileExists(atPath: systemURL.path),
           let p = energyProfile(url: systemURL) {
            sysSegs = segments(from: p.rms, window: p.windowSeconds, speaker: .other)
        }
        segs = removeEcho(mic: micSegs, system: sysSegs) + sysSegs

        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var chunks: [Chunk] = []
        for (i, r) in chunkRanges(segs).enumerated() {
            let src = r.speaker == .me ? micURL : (systemURL ?? micURL)
            let url = workDir.appendingPathComponent(String(format: "chunk-%03d-%@.m4a", i, r.speaker == .me ? "me" : "other"))
            do {
                try export(source: src, start: r.start, end: r.end, to: url)
                chunks.append(Chunk(speaker: r.speaker, start: r.start, end: r.end, fileURL: url))
            } catch {
                NSLog("[VF-Call] chunk export failed: %@", String(describing: error))
            }
        }
        return chunks
    }
}
