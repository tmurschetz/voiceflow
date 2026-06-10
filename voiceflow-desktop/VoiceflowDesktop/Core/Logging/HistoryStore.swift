import Foundation

/// Local dictation history — append-only JSONL file in Application Support.
///
/// Every dictation (success or failure) is appended as one JSON line:
///   {"date":"2026-06-10T09:12:33Z","mode":"business","raw":"…","final":"…",
///    "audioSeconds":12,"success":true,"usedFallback":false}
///
/// Privacy: the file never leaves the Mac. Users can open the folder from the
/// menu bar (right-click → "Verlauf öffnen") or delete it at any time.
final class HistoryStore {

    struct Entry: Codable {
        let date: Date
        let mode: String
        let raw: String?
        let final: String?
        let audioSeconds: Int?
        let success: Bool
        let usedFallback: Bool
        let errorMessage: String?
    }

    static let shared = HistoryStore()

    /// ~/Library/Application Support/Voiceflow/history.jsonl
    let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Voiceflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let queue = DispatchQueue(label: "com.voiceflow.desktop.history", qos: .utility)

    // MARK: - Append

    func logCompleted(mode: ProcessingMode, raw: String, final: String,
                      audioSeconds: Int?, usedFallback: Bool) {
        append(Entry(date: Date(), mode: mode.rawValue, raw: raw, final: final,
                     audioSeconds: audioSeconds, success: true,
                     usedFallback: usedFallback, errorMessage: nil))
    }

    func logFailed(mode: ProcessingMode, errorMessage: String) {
        append(Entry(date: Date(), mode: mode.rawValue, raw: nil, final: nil,
                     audioSeconds: nil, success: false,
                     usedFallback: false, errorMessage: errorMessage))
    }

    private func append(_ entry: Entry) {
        queue.async { [fileURL, encoder] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A) // newline
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    // MARK: - Read

    /// Returns the most recent entries (newest first). Reads the whole file —
    /// fine for a personal dictation log (a year of heavy use is a few MB).
    func recent(limit: Int = 20) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content.split(separator: "\n")
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
            .suffix(limit)
            .reversed()
    }
}
