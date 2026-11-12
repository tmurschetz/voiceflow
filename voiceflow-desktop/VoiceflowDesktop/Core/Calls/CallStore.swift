import Foundation

/// Local store for call transcripts: one folder per call under
/// ~/Library/Application Support/Voiceflow/Calls/<id>/ (audio tracks + transcript)
/// plus an index `calls.jsonl`. Retention: 14 days, purged at launch.
final class CallStore {

    struct Record: Codable, Identifiable {
        var id: String
        var start: Date
        var end: Date
        var source: String                 // manual | teams-auto
        var participant: String?           // best guess (Teams window title)
        var hints: [String] = []           // raw titles seen, for later refinement
        var languages: [String] = []
        var status: String                 // processing | done | failed
        var transcript: String = ""
        var errorMessage: String? = nil
        var systemAudioMissing: Bool = false

        var durationSeconds: Int { Int(end.timeIntervalSince(start)) }
    }

    static let shared = CallStore()
    static let retentionDays = 14

    let baseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Voiceflow/Calls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var indexURL: URL { baseURL.appendingPathComponent("calls.jsonl") }

    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private let queue = DispatchQueue(label: "com.voiceflow.desktop.calls", qos: .utility)

    func folder(for id: String) -> URL { baseURL.appendingPathComponent(id, isDirectory: true) }

    // MARK: - Read

    /// All records, newest first.
    func all() -> [Record] {
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        // Last write per id wins (records are appended on every status change).
        var byID: [String: Record] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            guard let r = try? decoder.decode(Record.self, from: Data(line.utf8)) else { continue }
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id] = r
        }
        return order.compactMap { byID[$0] }.sorted { $0.start > $1.start }
    }

    // MARK: - Write

    /// Appends/updates a record (append-only log; readers take the last entry).
    func upsert(_ record: Record) {
        queue.sync { [indexURL, encoder] in
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: indexURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
            } else {
                try? line.write(to: indexURL)
            }
        }
        // Keep a human-readable copy next to the audio.
        if !record.transcript.isEmpty {
            try? record.transcript.write(to: folder(for: record.id).appendingPathComponent("transcript.txt"),
                                         atomically: true, encoding: .utf8)
        }
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        rewriteIndex(all().filter { $0.id != id })
    }

    /// Removes calls older than the retention window (folders + index lines).
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let records = all()
        let expired = records.filter { $0.end < cutoff }
        for r in expired { try? FileManager.default.removeItem(at: folder(for: r.id)) }
        if !expired.isEmpty { rewriteIndex(records.filter { $0.end >= cutoff }) }
        return expired.count
    }

    private func rewriteIndex(_ records: [Record]) {
        queue.sync { [indexURL, encoder] in
            let lines = records.compactMap { try? encoder.encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
            try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                .write(to: indexURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Formatting

    /// Transcript header + body, ready to paste into a CRM / Copilot.
    static func exportText(_ r: Record) -> String {
        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        var head = "Call · \(df.string(from: r.start)) · \(tf.string(from: r.start))–\(tf.string(from: r.end)) (\(max(1, r.durationSeconds / 60)) Min)"
        if let p = r.participant, !p.isEmpty { head += "\nTeilnehmer: \(p)" }
        if !r.languages.isEmpty { head += "\nSprache: \(r.languages.joined(separator: ", "))" }
        return head + "\n\n" + r.transcript
    }
}
