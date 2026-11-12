import AVFoundation
import Foundation

/// A call recording session: microphone (you) and system audio (the other
/// side) as two separate tracks. Separate tracks make speaker attribution
/// exact — no diarisation model needed — and keep dictation (RecordingService)
/// completely independent: both can run without touching each other's state.
final class CallRecordingService {

    struct Session {
        let id: String
        let folder: URL
        let micURL: URL
        let systemURL: URL
        let startedAt: Date
        var source: String            // "manual" | "teams-auto"
        var participantHints: Set<String> = []   // Teams window titles seen during the call
    }

    private(set) var session: Session?
    private var micRecorder: AVAudioRecorder?
    private let systemTap = SystemAudioTap()
    /// True when system audio could not be captured (permission denied) and the
    /// call is being recorded mic-only.
    private(set) var systemAudioUnavailable = false

    var isRecording: Bool { session != nil }

    /// Elapsed seconds of the running call.
    var elapsedSeconds: Int {
        guard let s = session else { return 0 }
        return Int(Date().timeIntervalSince(s.startedAt))
    }

    // MARK: - Start / stop

    func start(folderBase: URL, source: String) throws {
        guard session == nil else { return }
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = folderBase.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.m4a")
        let sysURL = folder.appendingPathComponent("system.m4a")

        // Mic track — the proven dictation settings (32 kHz / 96 kbps mono).
        let recorder = try AVAudioRecorder(url: micURL, settings: RecordingService.preferredRecorderSettings)
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecordingError.couldNotStart
        }
        micRecorder = recorder

        // System track — best effort: a denied permission must not kill the call.
        do {
            try systemTap.start(to: sysURL)
            systemAudioUnavailable = false
        } catch {
            NSLog("[VF-Call] System audio unavailable: %@ — recording mic only", String(describing: error))
            systemAudioUnavailable = true
        }

        session = Session(id: id, folder: folder, micURL: micURL, systemURL: sysURL,
                          startedAt: Date(), source: source)
        NSLog("[VF-Call] Recording started (%@) → %@", source, folder.lastPathComponent)
    }

    /// Adds a participant hint (e.g. a Teams window title) to the running session.
    func noteParticipantHint(_ hint: String) {
        session?.participantHints.insert(hint)
    }

    /// Stops both tracks and returns the finished session (nil if none ran).
    func stop() -> Session? {
        guard let s = session else { return nil }
        micRecorder?.stop()
        micRecorder = nil
        if systemTap.isRunning { systemTap.stop() }
        session = nil
        NSLog("[VF-Call] Recording stopped after %ds", Int(Date().timeIntervalSince(s.startedAt)))
        return s
    }
}
