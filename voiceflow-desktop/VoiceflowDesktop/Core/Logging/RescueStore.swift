import Foundation

/// Keeps the audio of failed dictations so they can be retried instead of lost.
///
/// When the pipeline fails after recording (transcription or rewrite errors,
/// even after automatic retries), the audio file is MOVED here instead of being
/// deleted. The status panel then offers "Erneut versuchen" — and because the
/// files live in Application Support, the offer survives an app restart.
///
/// Layout: ~/Library/Application Support/Voiceflow/Rescue/<epochSeconds>_<mode>.<ext>
/// Pruned to the most recent 5 files so the folder can't grow unbounded.
final class RescueStore {

    static let shared = RescueStore()

    struct Rescued: Equatable {
        let fileURL: URL
        let mode: ProcessingMode
        let date: Date
    }

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Voiceflow/Rescue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Save

    /// Moves a failed recording into the rescue folder. Returns nil if the move fails.
    @discardableResult
    func save(fileURL: URL, mode: ProcessingMode) -> Rescued? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        let date = Date()
        let name = "\(Int(date.timeIntervalSince1970))_\(mode.rawValue).\(fileURL.pathExtension)"
        let dest = dir.appendingPathComponent(name)
        do {
            try fm.moveItem(at: fileURL, to: dest)
        } catch {
            NSLog("[RescueStore] Move failed: %@", String(describing: error))
            return nil
        }
        prune()
        NSLog("[RescueStore] Saved failed recording: %@", name)
        return Rescued(fileURL: dest, mode: mode, date: date)
    }

    // MARK: - Read

    /// The most recent rescued recording, or nil.
    var latest: Rescued? {
        allRescued().first
    }

    private func allRescued() -> [Rescued] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url -> Rescued? in
            // <epoch>_<mode>.<ext>
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 2,
                  let epoch = TimeInterval(parts[0]),
                  let mode = ProcessingMode(rawValue: String(parts[1])) else { return nil }
            return Rescued(fileURL: url, mode: mode, date: Date(timeIntervalSince1970: epoch))
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - Delete

    func delete(_ rescued: Rescued) {
        try? FileManager.default.removeItem(at: rescued.fileURL)
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func prune(keep: Int = 5) {
        let all = allRescued()
        guard all.count > keep else { return }
        for old in all.dropFirst(keep) {
            delete(old)
        }
    }
}
