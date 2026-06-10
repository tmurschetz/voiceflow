import AppKit
import SwiftUI

/// Headless UI-snapshot mode for design review and visual regression checks.
///
/// Launch the binary with `--snapshot <outputDir>` and it renders every screen
/// (onboarding, settings, status panel in all relevant states) to PNG files,
/// then exits.
///
/// Implementation: each view is hosted in a real (off-screen) NSWindow and
/// captured via `cacheDisplay` — this renders genuine AppKit controls
/// (TextFields, Toggles, grouped Form, KeyboardShortcuts.Recorder), which
/// SwiftUI's ImageRenderer cannot do, and requires no screen-recording
/// permission because it never touches the display server.
@MainActor
enum SnapshotMode {

    private struct Spec {
        let name: String
        let size: NSSize
        let view: AnyView
    }

    /// Returns true if snapshot mode was requested (caller must NOT start the
    /// normal app; termination happens here after the async captures finish).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--snapshot") else { return false }
        let outDir = args.indices.contains(flagIndex + 1)
            ? args[flagIndex + 1]
            : NSTemporaryDirectory() + "vf-snapshots"

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var settings = AppSettings()
        settings.shortcutPrivate  = "⌥1"
        settings.shortcutBusiness = "⌥2"
        settings.shortcutRandom   = "⌥3"

        var specs: [Spec] = [
            Spec(name: "onboarding", size: NSSize(width: 460, height: 520),
                 view: AnyView(OnboardingView(viewModel: OnboardingViewModel()))),
            Spec(name: "settings", size: NSSize(width: 580, height: 720),
                 view: AnyView(SettingsView(viewModel: SettingsViewModel(settingsService: SettingsService())))),
            // Full-height variant so design review sees every section without scrolling.
            Spec(name: "settings-full", size: NSSize(width: 580, height: 1540),
                 view: AnyView(SettingsScrollProbe()))
        ]

        let panelStates: [(String, AppState, String?)] = [
            ("panel-idle",      .idle, nil),
            ("panel-needskey",  .needsAPIKey, nil),
            ("panel-recording", .recording(mode: .business), nil),
            ("panel-success",   .success, "Das ist ein Beispieltext, der gerade diktiert und eingefügt wurde."),
            ("panel-fallback",  .successWithRawFallback, "Rohtext nach KI-Ausfall — trotzdem nichts verloren.")
        ]
        for (name, state, lastText) in panelStates {
            let vm = StatusPanelViewModel()
            vm.state = state
            vm.settings = settings
            vm.lastDictation = lastText
            if case .recording = state { vm.recordingSeconds = 42 }
            specs.append(Spec(name: name, size: NSSize(width: 300, height: 1),
                              view: AnyView(StatusPanelView(viewModel: vm, onSettings: {}, onQuit: {}))))
        }

        Task { @MainActor in
            for spec in specs {
                await capture(spec, outDir: outDir)
            }
            print("SNAPSHOTS_WRITTEN:\(outDir)")
            NSApp.terminate(nil)
        }
        return true
    }

    /// Tall, non-scrolling rendering of the Settings form for design review.
    private struct SettingsScrollProbe: View {
        var body: some View {
            SettingsView(viewModel: SettingsViewModel(settingsService: SettingsService()),
                         height: 1540)
        }
    }

    /// Hosts the view in an off-screen window, waits for SwiftUI layout to
    /// settle, then captures the content view into a PNG.
    private static func capture(_ spec: Spec, outDir: String) async {
        let hosting = NSHostingView(rootView: spec.view)

        // Height 1 = self-sizing (status panel): use the hosting view's fitting size.
        var size = spec.size
        if size.height <= 1 {
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: 10))
            let fitting = hosting.fittingSize
            size = NSSize(width: size.width, height: max(fitting.height, 200))
        }

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.colorSpace = .sRGB
        // Order the window in (off-screen origin) so SwiftUI attaches and lays out.
        window.orderBack(nil)

        // Let SwiftUI/AppKit complete layout + first render pass.
        try? await Task.sleep(nanoseconds: 700_000_000)

        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("SNAPSHOT_FAILED:\(spec.name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let path = "\(outDir)/\(spec.name).png"
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT_OK:\(path)")
        } else {
            print("SNAPSHOT_FAILED:\(spec.name)")
        }
        window.orderOut(nil)
    }
}
