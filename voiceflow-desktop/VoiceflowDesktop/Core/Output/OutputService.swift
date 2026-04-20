import AppKit
import ApplicationServices
import CoreGraphics

/// Outputs the processed text into the currently focused text field or the clipboard.
///
/// # Strategy order for `.insertIntoField`
///
///  1. **AX value write** — sets `kAXValueAttribute` on the focused element directly.
///     Fast, cursor-position-aware, leaves the user's clipboard untouched.
///     Works for native AppKit / Cocoa text fields.
///     Requires Accessibility permission.
///
///  2. **Clipboard + ⌘V simulation** — writes text to `NSPasteboard`, then posts a
///     CGEvent ⌘V keystroke.  Works universally: browsers (Chrome, Safari, Firefox),
///     Electron apps, web views.  Does NOT require Accessibility permission.
///     Side-effect: overwrites the user's clipboard.
///
///  3. **Clipboard only** — written when mode is `.clipboardOnly`.
///     Also the silent last-resort if posting CGEvents fails.
final class OutputService {

    // MARK: - Public API

    func output(text: String, mode: OutputMode) async throws {
        switch mode {

        case .clipboardOnly:
            copyToClipboard(text)

        case .insertIntoField:
            // Strategy 1 — AX direct value write (native apps, no clipboard touch)
            if AXIsProcessTrusted() {
                let axError = attemptAXInsertion(text)
                if axError == .success { return }
                // Fall through on .cannotComplete (browser / Electron) or .noValue
                #if DEBUG
                print("[OutputService] AX insert failed (\(axError.rawValue)) — falling back to paste")
                #endif
            }

            // Strategy 2 — Clipboard + ⌘V (works in every app)
            copyToClipboard(text)
            simulatePasteKeystroke()
        }
    }

    // MARK: - Clipboard

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Strategy 1: AX Value Write

    /// Attempts to insert `text` at the cursor position of the focused UI element.
    /// Returns the `AXError` from the final `AXUIElementSetAttributeValue` call,
    /// or `.cannotComplete` if the element is not text-settable.
    private func attemptAXInsertion(_ text: String) -> AXError {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let fetchErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard fetchErr == .success, let ref = focusedRef else {
            return fetchErr == .success ? .noValue : fetchErr
        }
        // AXUIElement is a Core Foundation type bridged as AnyObject.
        // The cast is guaranteed to succeed when AXUIElementCopyAttributeValue succeeds.
        let element = ref as! AXUIElement // swiftlint:disable:this force_cast

        // Bail out early if the element's value isn't writable
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return .cannotComplete }

        // Read current text
        var currentRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentRef)
        let current = (currentRef as? String) ?? ""

        // Determine cursor insertion point from the selected-text range
        var rangeRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)

        var insertionIndex = current.endIndex
        if let rangeVal = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rangeVal as! AXValue, AXValueType(rawValue: kAXValueCFRangeType)!, &cfRange), // swiftlint:disable:this force_cast
               cfRange.location >= 0, cfRange.location <= current.count {
                insertionIndex = current.index(current.startIndex, offsetBy: cfRange.location)
            }
        }

        var updated = current
        updated.insert(contentsOf: text, at: insertionIndex)

        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        )
    }

    // MARK: - Strategy 2: CGEventPost ⌘V

    /// Posts a ⌘V keystroke to the active application.
    ///
    /// The clipboard must be populated before this is called.
    /// A 50 ms delay gives the target app time to notice the pasteboard change.
    ///
    /// Virtual key 9 = V on all standard keyboard layouts (it is a hardware position
    /// code, not a character code, so it is layout-independent for ⌘V).
    private func simulatePasteKeystroke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            else { return }
            keyDown.flags = .maskCommand
            keyUp.flags   = .maskCommand
            // .cgAnnotatedSessionEventTap targets the current frontmost application
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
