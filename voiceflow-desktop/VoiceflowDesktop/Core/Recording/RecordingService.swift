import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation

// MARK: - RecordedAudio

/// The result of a completed recording.
/// Caller is responsible for calling `cleanup()` when done with the file.
struct RecordedAudio {
    let fileURL: URL

    /// Read the raw audio bytes on demand (e.g. for multipart upload).
    func data() throws -> Data {
        try Data(contentsOf: fileURL)
    }

    /// Delete the temp file. Call this once the pipeline is complete.
    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - RecordingService

/// Manages microphone capture via AVFoundation.
///
/// ## Device selection
///
/// When `deviceID` is **nil** (or the requested device cannot be found), recording
/// uses an `AVAudioRecorder` with the system default input device.  Output: `.m4a`.
///
/// When `deviceID` is a known `AVCaptureDevice.uniqueID`, recording switches to an
/// `AVAudioEngine` tap pointed at that specific Core Audio device.  Output: `.caf`
/// (raw PCM in a CAF container).  Both formats are accepted by `SFSpeechRecognizer`.
final class RecordingService {

    private(set) var isRecording: Bool       = false
    private(set) var recordingStartedAt: Date?

    // System-default path
    private var audioRecorder: AVAudioRecorder?

    // Specific-device path
    private var audioEngine: AVAudioEngine?
    private var audioFile:   AVAudioFile?   // written by the engine tap

    private var tempFileURL: URL?

    // MARK: - Start

    /// Starts recording audio to a temp file.
    ///
    /// - Parameter deviceID: `AVCaptureDevice.uniqueID` of the desired input device,
    ///   or nil to use the system default.
    func startRecording(deviceID: String? = nil) async throws {
        guard !isRecording else { return }

        // Request microphone permission before attempting to record
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else { throw RecordingError.microphonePermissionDenied }

        if let uid = deviceID,
           let coreAudioDeviceID = Self.findCoreAudioDeviceID(forUID: uid) {
            // Specific device — use AVAudioEngine with a tap
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vf_\(UUID().uuidString).caf")
            tempFileURL = url
            try startEngineRecording(deviceID: coreAudioDeviceID, to: url)
        } else {
            // System default: voice-processed capture first (Apple's noise
            // suppression + echo cancellation + auto gain — the same class of
            // pre-processing ChatGPT & Co. apply before transcription). If the
            // voice-processing engine fails for any reason, fall back to the
            // proven plain AVAudioRecorder path — recording must never die.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vf_\(UUID().uuidString).m4a")
            tempFileURL = url
            do {
                try startVoiceProcessedRecording(to: url)
                NSLog("[VF-Record] Voice-processed capture active")
            } catch {
                NSLog("[VF-Record] Voice processing unavailable (%@) — plain recorder",
                      String(describing: error))
                try startRecorderRecording(to: url)
            }
        }

        recordingStartedAt = Date()
        isRecording = true
    }

    // MARK: - Stop

    /// Stops recording and returns a `RecordedAudio` handle pointing to the temp file.
    /// The caller must call `audio.cleanup()` when the pipeline is done.
    func stopRecording() async throws -> RecordedAudio {
        guard isRecording, let url = tempFileURL else {
            throw RecordingError.notRecording
        }

        if let engine = audioEngine {
            // Remove tap first so no more buffers arrive, then stop the engine.
            // Setting audioFile = nil drops the last strong reference, which flushes
            // the AVAudioFile and finalises the CAF container.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            audioFile   = nil
        } else if let recorder = audioRecorder {
            recorder.stop()
            audioRecorder = nil
        }

        isRecording = false
        tempFileURL = nil
        return RecordedAudio(fileURL: url)
    }

    /// Approximate duration in seconds of the current (or most recent) recording.
    var currentDurationSeconds: Int {
        guard let start = recordingStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    // MARK: - Private: AVAudioRecorder path (system default device)

    /// Preferred capture: 32 kHz mono AAC @ 96 kbps — transparent for speech,
    /// ~720 KB/min. IMPORTANT: Apple's AAC encoder only accepts certain
    /// sample-rate/bitrate pairs (e.g. 24 kHz mono caps at 64 kbps; 96 kbps
    /// there makes prepareToRecord() fail and recording never starts — the
    /// v1.1 pre-release bug). 32 kHz mono allows up to 96 kbps. Sample rate
    /// must be a Double.
    static let preferredRecorderSettings: [String: Any] = [
        AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey:       32_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey:   96_000
    ]

    /// Known-good since v1.0 — safety net if the preferred settings are ever
    /// rejected by the encoder (OS quirks, future hardware).
    static let fallbackRecorderSettings: [String: Any] = [
        AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey:       16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey:   32_000
    ]

    private func startRecorderRecording(to url: URL) throws {
        // Try preferred quality first; fall back rather than fail — a dictation
        // app must never be unable to record because of an encoder range check.
        for (idx, settings) in [Self.preferredRecorderSettings,
                                Self.fallbackRecorderSettings].enumerated() {
            guard let recorder = try? AVAudioRecorder(url: url, settings: settings),
                  recorder.prepareToRecord(),
                  recorder.record() else {
                if idx == 0 {
                    NSLog("[VF-Record] Preferred settings rejected — falling back to 16 kHz/32 kbps")
                }
                continue
            }
            audioRecorder = recorder
            return
        }
        throw RecordingError.couldNotStart
    }

    // MARK: - Private: voice-processed path (system default device)

    /// AAC bitrates are only valid in certain ranges per sample rate (see the
    /// preferred/fallback settings above) — the voice-processing unit dictates
    /// the rate, so the bitrate adapts to it.
    static func vpBitrate(forSampleRate rate: Double) -> Int {
        if rate >= 32_000 { return 96_000 }
        if rate >= 22_050 { return 64_000 }
        return 48_000
    }

    /// Captures through Apple's voice-processing unit: noise suppression, echo
    /// cancellation and automatic gain control — the input is levelled and
    /// cleaned before it ever reaches the encoder, which is a large part of why
    /// ChatGPT-style recorders "understand" better in real rooms.
    private func startVoiceProcessedRecording(to url: URL) throws {
        let engine    = AVAudioEngine()
        let inputNode = engine.inputNode
        try inputNode.setVoiceProcessingEnabled(true)

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.couldNotStart
        }

        let settings: [String: Any] = [
            AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:       format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey:   Self.vpBitrate(forSampleRate: format.sampleRate)
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        audioFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak file] buffer, _ in
            guard let f = file else { return }
            try? f.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    // MARK: - Private: AVAudioEngine path (specific device)

    private func startEngineRecording(deviceID: AudioDeviceID, to url: URL) throws {
        let engine    = AVAudioEngine()
        let inputNode = engine.inputNode

        // Point the HAL output unit at the requested device.
        // This must happen before `engine.prepare()` so the hardware is
        // initialised with the correct device from the start.
        guard let audioUnit = inputNode.audioUnit else {
            throw RecordingError.couldNotStart
        }
        var deviceIDVar = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else {
            #if DEBUG
            print("[RecordingService] AudioUnitSetProperty failed: \(setStatus)")
            #endif
            throw RecordingError.couldNotStart
        }

        // Prepare the engine — this finalises the hardware connection and makes
        // `inputFormat(forBus:)` return a valid, non-zero sample rate.
        engine.prepare()

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecordingError.couldNotStart
        }

        // Write raw PCM to a CAF container.  SFSpeechRecognizer reads CAF natively.
        let file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        audioFile = file

        // The tap delivers buffers on a real-time thread; writing is non-throwing
        // in practice since the file was just created and the disk has space.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak file] buffer, _ in
            guard let f = file else { return }
            try? f.write(from: buffer)
        }

        try engine.start()
        audioEngine = engine
    }

    // MARK: - Device UID → Core Audio AudioDeviceID

    /// Converts an `AVCaptureDevice.uniqueID` string to the opaque `AudioDeviceID`
    /// used by Core Audio APIs such as `AudioUnitSetProperty`.
    ///
    /// Returns `nil` if no device with that UID is currently attached.
    static func findCoreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID = uid as CFString

        // AudioValueTranslation asks Core Audio to look up a device by its UID.
        // We need stable pointers for the duration of the call, so we use
        // withUnsafeMutablePointer to pin both the input (CFString) and output.
        let found: Bool = withUnsafeMutablePointer(to: &cfUID) { inputPtr in
            withUnsafeMutablePointer(to: &deviceID) { outputPtr in
                var translation = AudioValueTranslation(
                    mInputData:     UnsafeMutableRawPointer(inputPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData:    UnsafeMutableRawPointer(outputPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size: UInt32 = UInt32(MemoryLayout<AudioValueTranslation>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope:    kAudioObjectPropertyScopeGlobal,
                    mElement:  kAudioObjectPropertyElementMain
                )
                let status = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0, nil,
                    &size,
                    &translation
                )
                // Read through outputPtr to avoid an exclusivity violation:
                // `deviceID` is mutably borrowed for the duration of this closure,
                // so we must not also read it directly.
                return status == noErr && outputPtr.pointee != kAudioObjectUnknown
            }
        }
        return found ? deviceID : nil
    }

    // MARK: - Available Input Devices

    /// Returns the list of audio input devices available on this Mac.
    /// Used to populate the microphone picker in Settings.
    /// The `id` field maps to `user_settings.microphone_device`.
    static func availableInputDevices() -> [(id: String, name: String)] {
        // .microphone and .external were introduced in macOS 14 (Sonoma).
        // On macOS 13 (Ventura) we use the legacy .builtInMicrophone type.
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { device in
            (id: device.uniqueID, name: device.localizedName)
        }
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case notRecording
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy → Microphone."
        case .notRecording:
            return "No active recording to stop."
        case .couldNotStart:
            return "Could not start audio recording. Check microphone connection."
        }
    }
}
