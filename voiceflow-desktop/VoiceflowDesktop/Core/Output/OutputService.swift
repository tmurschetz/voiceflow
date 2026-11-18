import AppKit
import ApplicationServices
import CoreGraphics

/// Outputs the processed text into the currently focused text field or the clipboard.
///
/// `.insertIntoField` = clipboard + ⌘V, always (build 34). The earlier first
/// strategy — writing the field's whole AX value — was dropped: browser and
/// Electron fields (Teams, new Outlook, web apps) often applied the write but
/// reported an error, so the ⌘V fallback inserted the text a SECOND time, and
/// in other fields the write "succeeded" without the app noticing.
///
/// The ⌘V goes to the active window through the HID event tap (not to a
/// process id, which web-based apps ignore), only after the target app is
/// really frontmost. The user's previous clipboard is restored afterwards,
/// unless something else was copied in the meantime.
///
/// Return value: `true` if the text was only placed on the clipboard (mode
/// `.clipboardOnly`, or no Accessibility permission to send ⌘V).
@MainActor
final class OutputService {

    /// Delay before the previous clipboard comes back — long enough for slow
    /// (Electron) apps to read the pasteboard after ⌘V.
    static let restoreDelaySeconds: Double = 2.0

    // MARK: - Public API

    @discardableResult
    func output(text: String, mode: OutputMode, targetPID: pid_t? = nil) async throws -> Bool {
        switch mode {
        case .clipboardOnly:
            copyToClipboard(text)
            return true

        case .insertIntoField:
            // Without Accessibility we can't send ⌘V — leave it on the clipboard.
            guard AXIsProcessTrusted() else {
                copyToClipboard(text)
                return true
            }
            let previous = snapshotPasteboard()
            copyToClipboard(text)
            let ourChange = NSPasteboard.general.changeCount

            await bringToFront(targetPID)
            postPasteKeystroke()

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelaySeconds * 1_000_000_000))
                // Only if nobody (user or app) changed the clipboard since.
                guard NSPasteboard.general.changeCount == ourChange else { return }
                self.restorePasteboard(previous)
            }
            return false
        }
    }

    // MARK: - Clipboard

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }

    // MARK: - Paste

    /// Activates the app that was frontmost when the dictation stopped and waits
    /// (≤ 0.8 s) until it really is frontmost — activation is asynchronous, and a
    /// ⌘V sent too early lands nowhere.
    private func bringToFront(_ pid: pid_t?) async {
        guard let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) else {
            try? await Task.sleep(nanoseconds: 60_000_000)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            app.activate()
            for _ in 0..<40 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            NSLog("[VF-Paste] activated pid=%d frontmost=%@", Int(pid),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? "YES" : "NO")
        }
        // Let the focused field settle (key window, first responder).
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// ⌘ down, V down, V up, ⌘ up — a full chord, like a real keyboard. Some
    /// Electron apps ignore a bare V carrying only the command flag.
    private func postPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmd: CGKeyCode = 55, v: CGKeyCode = 9
        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true),
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        else {
            NSLog("[VF-Paste] CGEvent creation FAILED")
            return
        }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        for e in [cmdDown, vDown, vUp, cmdUp] { e.post(tap: .cghidEventTap) }
        NSLog("[VF-Paste] posted ⌘V to frontmost=%d",
              Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1))
    }
}
