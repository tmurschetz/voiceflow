import Foundation

/// Maps to the `transcription_sessions` table.
///
/// Exact columns used on INSERT:
///   user_id, mode, detected_language, output_mode,
///   started_at, finished_at, audio_seconds,
///   success, error_message,
///   transcription_provider, processing_provider,
///   raw_transcript, final_text,
///   duration_seconds, word_count, character_count, status
///
/// created_at is set by the DB DEFAULT NOW() — not sent in the body.
struct TranscriptionSessionInsert: Encodable {
    let userId: UUID
    let mode: String                      // 'private' | 'business' | 'calm'
    let detectedLanguage: String?         // 'de' | 'en' | 'gsw' | 'auto' | nil
    let outputMode: String                // matches DB output_mode values
    let startedAt: Date?
    let finishedAt: Date?
    let audioSeconds: Int?
    let success: Bool
    let errorMessage: String?
    let transcriptionProvider: String?   // e.g. "openai-whisper"
    let processingProvider: String?      // e.g. "openai-gpt4"
    let rawTranscript: String?
    let finalText: String?
    let durationSeconds: Int             // wall-clock duration of the whole pipeline
    let wordCount: Int
    let characterCount: Int
    let status: String                   // 'completed' | 'failed'

    // Supabase uses snake_case column names — encoder uses convertToSnakeCase
    private enum CodingKeys: String, CodingKey {
        case userId             = "user_id"
        case mode
        case detectedLanguage   = "detected_language"
        case outputMode         = "output_mode"
        case startedAt          = "started_at"
        case finishedAt         = "finished_at"
        case audioSeconds       = "audio_seconds"
        case success
        case errorMessage       = "error_message"
        case transcriptionProvider = "transcription_provider"
        case processingProvider    = "processing_provider"
        case rawTranscript      = "raw_transcript"
        case finalText          = "final_text"
        case durationSeconds    = "duration_seconds"
        case wordCount          = "word_count"
        case characterCount     = "character_count"
        case status
    }
}

// MARK: - Convenience builder

extension TranscriptionSessionInsert {
    /// Build a completed-session log record.
    static func completed(
        userId: UUID,
        mode: ProcessingMode,
        rawTranscript: String,
        finalText: String,
        detectedLanguage: String?,
        outputMode: OutputMode,
        startedAt: Date,
        audioSeconds: Int?
    ) -> TranscriptionSessionInsert {
        let now = Date()
        return TranscriptionSessionInsert(
            userId: userId,
            mode: mode.rawValue,
            detectedLanguage: detectedLanguage,
            outputMode: outputMode.dbValue,
            startedAt: startedAt,
            finishedAt: now,
            audioSeconds: audioSeconds,
            success: true,
            errorMessage: nil,
            transcriptionProvider: nil,   // fill when transcription is wired
            processingProvider: nil,      // fill when processing is wired
            rawTranscript: rawTranscript,
            finalText: finalText,
            durationSeconds: Int(now.timeIntervalSince(startedAt)),
            wordCount: finalText.split(separator: " ").count,
            characterCount: finalText.count,
            status: "completed"
        )
    }

    /// Build a failed-session log record.
    static func failed(
        userId: UUID,
        mode: ProcessingMode,
        errorMessage: String,
        outputMode: OutputMode,
        startedAt: Date
    ) -> TranscriptionSessionInsert {
        let now = Date()
        return TranscriptionSessionInsert(
            userId: userId,
            mode: mode.rawValue,
            detectedLanguage: nil,
            outputMode: outputMode.dbValue,
            startedAt: startedAt,
            finishedAt: now,
            audioSeconds: nil,
            success: false,
            errorMessage: errorMessage,
            transcriptionProvider: nil,
            processingProvider: nil,
            rawTranscript: nil,
            finalText: nil,
            durationSeconds: Int(now.timeIntervalSince(startedAt)),
            wordCount: 0,
            characterCount: 0,
            status: "failed"
        )
    }
}
