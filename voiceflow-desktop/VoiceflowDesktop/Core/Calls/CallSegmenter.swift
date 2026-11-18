import Accelerate
import AVFoundation
import Foundation

/// Turns the two call tracks into speaker-labelled chunks WITHOUT a diarisation
/// model: energy-based voice activity per track → speech segments → merged into
/// turns, cut at natural pauses, ≤ 2 minutes each. Each chunk is exported as a
/// 16 kHz mono WAV for transcription (no re-encoding cost, well under 25 MB).
///
/// 2.0 (build 34) — measured on a real 46-min Teams call on laptop speakers:
/// the far side leaks into the microphone at ~2/3 of its level, 100 ms late, and
/// 70 % of the mic's "speech" was that echo. Echo is therefore removed per
/// 50 ms window (not per segment), the mic-only stretch before/after the call is
/// trimmed, and short interjections no longer split a speaker's turn — which cut
/// a 46-min call from ~270 uploads to a fraction.
enum CallSegmenter {

    enum Speaker: String { case me = "Du", other = "Gegenseite" }

    struct Segment {
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    struct Chunk {
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        let fileURL: URL
    }

    // Tunables (seconds / linear RMS).
    static let windowSeconds: TimeInterval     = 0.05
    static let closeGapSeconds: TimeInterval   = 0.8    // silence that ends a segment
    static let minSegmentSeconds: TimeInterval = 1.0    // shorter = "mhm"/clicks → phantom text
    static let padSeconds: TimeInterval        = 0.2
    static let mergeGapSeconds: TimeInterval   = 3.0    // same speaker, short gap → one chunk
    static let interjectionSeconds: TimeInterval = 1.5  // other side's "ja"/"genau" doesn't split a turn
    static let maxChunkSeconds: TimeInterval   = 120
    /// Own speech must be this much louder than the expected echo (≈ 6 dB).
    static let echoMargin: Float = 2.0
    /// Kept around the far side's first/last words when trimming.
    static let trimMarginSeconds: TimeInterval = 20
    static let exportSampleRate: Double = 16_000

    // MARK: - Energy analysis

    /// RMS per 50 ms window, mono-mixed. nil if unreadable.
    static func energyProfile(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let win = max(1, Int(fmt.sampleRate * windowSeconds))
        let capacity = win * 200
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(capacity)),
              let ch = buf.floatChannelData else { return nil }
        let channels = Int(fmt.channelCount)
        var rms: [Float] = []
        rms.reserveCapacity(Int(file.length) / win + 1)
        var pending: [Float] = []   // samples carried into the next read
        var mono = [Float](repeating: 0, count: capacity)
        while true {
            do { try file.read(into: buf) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            // Mono mix with vDSP — the per-sample Swift loop was the main CPU cost.
            mono.withUnsafeMutableBufferPointer { m in
                m.baseAddress!.update(from: ch[0], count: n)
                for c in 1..<max(1, channels) {
                    vDSP_vadd(m.baseAddress!, 1, ch[c], 1, m.baseAddress!, 1, vDSP_Length(n))
                }
                if channels > 1 {
                    var scale = 1 / Float(channels)
                    vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(n))
                }
            }
            pending.append(contentsOf: mono[0..<n])
            var i = 0
            pending.withUnsafeBufferPointer { p in
                while i + win <= p.count {
                    var ms: Float = 0
                    vDSP_measqv(p.baseAddress! + i, 1, &ms, vDSP_Length(win))
                    rms.append(ms.squareRoot())
                    i += win
                }
            }
            pending.removeFirst(i)
        }
        if !pending.isEmpty {
            var ms: Float = 0
            pending.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &ms, vDSP_Length($0.count)) }
            rms.append(ms.squareRoot())
        }
        return rms
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * p)]
    }

    /// Speech threshold adapted to the track's noise floor (20th percentile), so
    /// a quiet headset and a loud room both work.
    static func threshold(_ rms: [Float]) -> Float {
        max(percentile(rms, 0.2) * 3.5, 0.004)
    }

    static func activity(_ rms: [Float]) -> [Bool] {
        let t = threshold(rms)
        return rms.map { $0 > t }
    }

    // MARK: - Echo removal (per window)

    /// Delay of the far side's echo in the mic, in windows (best log-energy
    /// correlation, 0…600 ms). Speakers + room are typically ~100 ms.
    static func echoLag(mic: [Float], system: [Float]) -> Int {
        let n = min(mic.count, system.count)
        guard n > 200 else { return 0 }
        let lm = mic.prefix(n).map { log10(max($0, 1e-5)) }
        let ls = system.prefix(n).map { log10(max($0, 1e-5)) }
        var best = (lag: 0, r: -Double.infinity)
        for lag in 0...12 {
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, k = 0.0
            var i = lag
            while i < n {
                let x = Double(ls[i - lag]), y = Double(lm[i])
                sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; k += 1
                i += 1
            }
            let cov = sxy / k - (sx / k) * (sy / k)
            let vx = sxx / k - (sx / k) * (sx / k), vy = syy / k - (sy / k) * (sy / k)
            guard vx > 0, vy > 0 else { continue }
            let r = cov / (vx * vy).squareRoot()
            if r > best.r { best = (lag, r) }
        }
        return best.lag
    }

    /// Windows in which the mic carries YOUR voice rather than the far side
    /// leaking through the speakers. Echo gain is estimated as the median
    /// mic/system ratio while the far side talks (people rarely talk over each
    /// other); own speech must exceed that expected echo by `echoMargin`.
    /// With a headset the estimated gain is tiny and nothing is removed.
    static func ownSpeechMask(mic: [Float], system: [Float]) -> [Bool] {
        var active = activity(mic)
        guard !system.isEmpty else { return active }
        let n = mic.count
        let lag = echoLag(mic: mic, system: system)
        let sysThreshold = threshold(system)
        var ratios: [Float] = []
        for i in 0..<n {
            let j = i - lag
            if j >= 0, j < system.count, system[j] > sysThreshold * 2, system[j] > 0 {
                ratios.append(mic[i] / system[j])
            }
        }
        guard ratios.count > 40 else { return active }
        let gain = percentile(ratios, 0.5)
        for i in 0..<n where active[i] {
            var expected: Float = 0
            for d in -2...4 {   // lag jitter + room reverb tail
                let j = i - lag - d
                if j >= 0, j < system.count { expected = max(expected, system[j]) }
            }
            active[i] = mic[i] > echoMargin * gain * expected
        }
        // Majority smoothing (3 of 5) — removes isolated echo/own flickers.
        guard n > 4 else { return active }
        var smoothed = active
        for i in 2..<(n - 2) {
            var c = 0
            for d in -2...2 where active[i + d] { c += 1 }
            smoothed[i] = c >= 3
        }
        return smoothed
    }

    // MARK: - Segments

    static func segments(from active: [Bool], window: TimeInterval, speaker: Speaker) -> [Segment] {
        var out: [Segment] = []
        var startIdx: Int? = nil
        var lastActive = -1
        let gapWindows = Int(closeGapSeconds / window)
        func close() {
            guard let s = startIdx else { return }
            let start = max(0, Double(s) * window - padSeconds)
            let end = Double(lastActive + 1) * window + padSeconds
            if end - start >= minSegmentSeconds {
                out.append(Segment(speaker: speaker, start: start, end: end))
            }
            startIdx = nil
        }
        for (i, a) in active.enumerated() {
            if a {
                if startIdx == nil { startIdx = i }
                lastActive = i
            } else if startIdx != nil, i - lastActive > gapWindows {
                close()
            }
        }
        if startIdx != nil { close() }
        return out
    }

    /// Drops your segments that lie entirely before the far side's first words or
    /// after their last ones (minus a margin): room talk before joining, the
    /// coffee-machine chat after hanging up. Only when the far side actually spoke.
    static func trimToCall(mic: [Segment], system: [Segment]) -> [Segment] {
        let spoken = system.reduce(0) { $0 + $1.duration }
        guard spoken >= 10, let first = system.map(\.start).min(), let last = system.map(\.end).max() else { return mic }
        let from = first - trimMarginSeconds, to = last + trimMarginSeconds
        return mic.filter { $0.end > from && $0.start < to }
    }

    /// Merges consecutive same-speaker segments into chunk ranges. A short
    /// interjection of the other side in between ("ja", "genau") does not split
    /// the turn. Capped at `maxChunkSeconds`, ordered by time.
    static func chunkRanges(_ segments: [Segment]) -> [(speaker: Speaker, start: TimeInterval, end: TimeInterval)] {
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [(speaker: Speaker, start: TimeInterval, end: TimeInterval)] = []
        var i = 0
        while i < sorted.count {
            let seg = sorted[i]
            if let last = out.last, last.speaker == seg.speaker,
               seg.start - last.end <= mergeGapSeconds,
               seg.end - last.start <= maxChunkSeconds {
                out[out.count - 1].end = max(last.end, seg.end)
                i += 1; continue
            }
            // Interjection: short other-side segment followed by the same speaker
            // continuing → swallow it into the running turn.
            if let last = out.last, last.speaker != seg.speaker,
               seg.duration <= interjectionSeconds,
               i + 1 < sorted.count, sorted[i + 1].speaker == last.speaker,
               sorted[i + 1].start - last.end <= mergeGapSeconds + interjectionSeconds,
               sorted[i + 1].end - last.start <= maxChunkSeconds {
                i += 1; continue
            }
            out.append((seg.speaker, seg.start, seg.end))
            i += 1
        }
        return out
    }

    // MARK: - Export

    /// Writes the [start, end] range of `source` as 16 kHz mono 16-bit WAV.
    static func export(source: URL, start: TimeInterval, end: TimeInterval, to url: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let inFmt = inFile.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: exportSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw NSError(domain: "CallSegmenter", code: 1)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: exportSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let startFrame = AVAudioFramePosition(max(0, start) * inFmt.sampleRate)
        let endFrame = min(inFile.length, AVAudioFramePosition(end * inFmt.sampleRate))
        guard endFrame > startFrame else { return }
        inFile.framePosition = startFrame
        var remaining = AVAudioFrameCount(endFrame - startFrame)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32_768),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt,
                                            frameCapacity: AVAudioFrameCount(32_768 * exportSampleRate / inFmt.sampleRate) + 1024)
        else { return }
        var finished = false
        while !finished {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if remaining == 0 { outStatus.pointee = .endOfStream; return nil }
                do {
                    try inFile.read(into: inBuf, frameCount: min(remaining, inBuf.frameCapacity))
                } catch {
                    outStatus.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { remaining = 0; outStatus.pointee = .endOfStream; return nil }
                remaining -= inBuf.frameLength
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if outBuf.frameLength > 0 { try outFile.write(from: outBuf) }
            if status == .endOfStream || status == .error { finished = true }
        }
    }

    // MARK: - Pipeline

    struct Stats {
        var micSegments = 0, systemSegments = 0, trimmed = 0, chunks = 0
        var echoRemovedSeconds = 0.0
    }

    /// Analysis only (no export): speaker turns for one call.
    static func plan(micURL: URL, systemURL: URL?) -> (ranges: [(speaker: Speaker, start: TimeInterval, end: TimeInterval)], stats: Stats) {
        var stats = Stats()
        let micRMS = energyProfile(url: micURL) ?? []
        var sysRMS: [Float] = []
        if let systemURL, FileManager.default.fileExists(atPath: systemURL.path) {
            sysRMS = energyProfile(url: systemURL) ?? []
        }
        let rawMicActive = activity(micRMS)
        let ownMask = ownSpeechMask(mic: micRMS, system: sysRMS)
        stats.echoRemovedSeconds = Double(rawMicActive.filter { $0 }.count - ownMask.filter { $0 }.count) * windowSeconds

        let sysSegs = segments(from: activity(sysRMS), window: windowSeconds, speaker: .other)
        let micAll = segments(from: ownMask, window: windowSeconds, speaker: .me)
        let micSegs = trimToCall(mic: micAll, system: sysSegs)
        stats.micSegments = micSegs.count
        stats.systemSegments = sysSegs.count
        stats.trimmed = micAll.count - micSegs.count
        let ranges = chunkRanges(micSegs + sysSegs)
        stats.chunks = ranges.count
        return (ranges, stats)
    }

    /// Full pipeline for one call: analyse both tracks → chunks on disk.
    static func makeChunks(micURL: URL, systemURL: URL?, workDir: URL) -> [Chunk] {
        makeChunksWithStats(micURL: micURL, systemURL: systemURL, workDir: workDir).chunks
    }

    static func makeChunksWithStats(micURL: URL, systemURL: URL?, workDir: URL) -> (chunks: [Chunk], stats: Stats) {
        let (ranges, stats) = plan(micURL: micURL, systemURL: systemURL)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var chunks: [Chunk] = []
        for (i, r) in ranges.enumerated() {
            let src = r.speaker == .me ? micURL : (systemURL ?? micURL)
            let url = workDir.appendingPathComponent(String(format: "chunk-%03d-%@.wav", i, r.speaker == .me ? "me" : "other"))
            do {
                try export(source: src, start: r.start, end: r.end, to: url)
                chunks.append(Chunk(speaker: r.speaker, start: r.start, end: r.end, fileURL: url))
            } catch {
                NSLog("[VF-Call] chunk export failed: %@", String(describing: error))
            }
        }
        return (chunks, stats)
    }
}
