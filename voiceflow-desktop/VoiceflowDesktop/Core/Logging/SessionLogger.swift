import Foundation

/// Logs completed transcription sessions to the `transcription_sessions` table.
///
/// This is non-fatal: any error is swallowed so a logging failure never interrupts
/// the user-facing dictation flow.
///
/// Table: transcription_sessions
/// Columns written: user_id, mode, detected_language, output_mode, started_at,
///   finished_at, audio_seconds, success, error_message, transcription_provider,
///   processing_provider, raw_transcript, final_text, duration_seconds,
///   word_count, character_count, status
/// DB-managed: id (uuid, PK), created_at (DEFAULT NOW())
final class SessionLogger {

    private let api = APIClient.shared
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Log Completed Session

    func logCompleted(
        session: SupabaseSession,
        mode: ProcessingMode,
        rawTranscript: String,
        finalText: String,
        detectedLanguage: String?,
        outputMode: OutputMode,
        startedAt: Date,
        audioSeconds: Int? = nil,
        transcriptionProvider: String? = nil,
        processingProvider: String? = nil
    ) async {
        let record = TranscriptionSessionInsert.completed(
            userId: session.user.id,
            mode: mode,
            rawTranscript: rawTranscript,
            finalText: finalText,
            detectedLanguage: detectedLanguage,
            outputMode: outputMode,
            startedAt: startedAt,
            audioSeconds: audioSeconds
        )
        await insert(record: record, token: session.accessToken)
    }

    // MARK: - Log Failed Session

    func logFailed(
        session: SupabaseSession,
        mode: ProcessingMode,
        errorMessage: String,
        outputMode: OutputMode,
        startedAt: Date
    ) async {
        let record = TranscriptionSessionInsert.failed(
            userId: session.user.id,
            mode: mode,
            errorMessage: errorMessage,
            outputMode: outputMode,
            startedAt: startedAt
        )
        await insert(record: record, token: session.accessToken)
    }

    // MARK: - Internal

    private func insert(record: TranscriptionSessionInsert, token: String) async {
        do {
            let req = try api.request(
                path: Endpoints.transcriptionSessions,
                method: "POST",
                body: record,
                authToken: token,
                extraHeaders: ["Prefer": "return=minimal"]
            )
            try await api.perform(req)
        } catch {
            #if DEBUG
            print("[SessionLogger] Insert failed: \(error)")
            #endif
        }
    }
}
