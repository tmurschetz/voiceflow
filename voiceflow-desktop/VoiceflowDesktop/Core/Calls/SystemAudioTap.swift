import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays (the far side of a call) into an AAC file,
/// using a Core Audio process tap (macOS 14.2+). The tap is wrapped in a private
/// aggregate device whose IO proc hands us the mixed system audio.
///
/// Permission: the first tap triggers macOS's "System Audio Recording" prompt
/// (Info.plist: NSAudioCaptureUsageDescription). Denied → `start` throws.
final class SystemAudioTap {

    enum TapError: LocalizedError {
        case unsupportedOS, tapFailed(OSStatus), aggregateFailed(OSStatus), formatFailed, ioProcFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unsupportedOS:           return "Systemton-Aufnahme braucht macOS 14.2 oder neuer."
            case .tapFailed(let s):        return "Systemton-Tap konnte nicht erstellt werden (\(s)) — Berechtigung «Systemaudio-Aufnahme» erteilt?"
            case .aggregateFailed(let s):  return "Audio-Gerät für den Tap fehlgeschlagen (\(s))."
            case .formatFailed:            return "Audioformat des Systemtons unlesbar."
            case .ioProcFailed(let s):     return "Audio-Stream konnte nicht gestartet werden (\(s))."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private(set) var framesWritten: Int64 = 0
    private(set) var isRunning = false

    /// Starts capturing system audio into `url` (.m4a).
    func start(to url: URL) throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }

        // 1. Tap on all system audio except our own process.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Voiceflow Call Capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else { throw TapError.tapFailed(tapStatus) }
        tapID = tap

        // 2. The tap's stream format drives the file format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            teardown(); throw TapError.formatFailed
        }
        format = fmt

        // 3. Private aggregate device that contains only the tap.
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey:         "Voiceflow Call Capture",
            kAudioAggregateDeviceUIDKey:          "com.voiceflow.desktop.calltap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey:    true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey:      [[kAudioSubTapUIDKey: desc.uuid.uuidString]]
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aggStatus == noErr, agg != kAudioObjectUnknown else { teardown(); throw TapError.aggregateFailed(aggStatus) }
        aggregateID = agg

        // 4. Output file: AAC, matching the tap's rate/channels so buffers write 1:1.
        let channels = Int(fmt.channelCount)
        let bitrate = channels > 1 ? 128_000 : (fmt.sampleRate >= 32_000 ? 96_000 : 64_000)
        let settings: [String: Any] = [
            AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:       fmt.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey:   bitrate
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        file = f
        framesWritten = 0

        // 5. IO proc: every callback hands us the mixed system audio.
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.format, let file = self.file else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData) else { return }
            if (try? file.write(from: buffer)) != nil {
                self.framesWritten += Int64(buffer.frameLength)
            }
        }
        guard procStatus == noErr, let p = proc else { teardown(); throw TapError.ioProcFailed(procStatus) }
        ioProcID = p
        let startStatus = AudioDeviceStart(aggregateID, p)
        guard startStatus == noErr else { teardown(); throw TapError.ioProcFailed(startStatus) }
        isRunning = true
    }

    /// Stops capture and finalises the file.
    func stop() {
        if let p = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        ioProcID = nil
        file = nil   // releases → AAC container finalised
        teardown()
        isRunning = false
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { stop() }
}
