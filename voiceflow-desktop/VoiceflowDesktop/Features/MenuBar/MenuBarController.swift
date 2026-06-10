import AppKit
import SwiftUI

/// Delegate protocol so AppDelegate can respond to menu bar actions
/// without MenuBarController needing to import AppDelegate.
@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestSettings()
    func menuBarDidRequestHistory()
    func menuBarDidRequestCheckForUpdates()
    func menuBarDidRequestQuit()
}

/// Owns the NSStatusItem (menu bar icon) and the popover panel.
///
/// Left-click  → toggles the status-panel popover.
/// Right-click → shows a utility NSMenu (Settings, History, Check for Updates, Quit).
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    let statusPanelVM = StatusPanelViewModel()
    private weak var delegate: MenuBarControllerDelegate?

    // MARK: - Recording blink animation
    private var blinkTimer: Timer?
    private var blinkPhase = true

    // MARK: - Init

    init(delegate: MenuBarControllerDelegate) {
        self.delegate = delegate
        setupStatusItem()
        setupPopover()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = Self.brandIdleImage()
        // Receive both left- and right-mouse-up so we can differentiate them
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusButtonClicked(_:))
        button.target = self
    }

    /// The "idle" / branding image for the menu bar — a monochrome V-with-wave
    /// extracted from AppIcon.png. Falls back to the SF Symbol `waveform` if the
    /// bundled template image is missing (e.g. before `make icon` has run).
    private static func brandIdleImage() -> NSImage? {
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voiceflow")
        fallback?.isTemplate = true
        return fallback
    }

    // MARK: - Popover

    private func setupPopover() {
        let panel = StatusPanelView(
            viewModel: statusPanelVM,
            onSettings: { [weak self] in
                self?.closePopover()
                self?.delegate?.menuBarDidRequestSettings()
            },
            onQuit: { [weak self] in
                self?.closePopover()
                self?.delegate?.menuBarDidRequestQuit()
            }
        )

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 280, height: 340)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: panel)
        self.popover = pop
    }

    // MARK: - State Updates

    func update(state: AppState, settings: AppSettings? = nil) {
        statusPanelVM.state = state
        if let settings { statusPanelVM.settings = settings }
        updateIcon(for: state)

        // Start/stop blink animation based on state
        if case .recording = state {
            startBlinking()
        } else {
            stopBlinking()
        }

        // Reset recording timer when leaving recording state
        if case .recording = state { /* keep counting */ } else {
            statusPanelVM.recordingSeconds = 0
        }
    }

    /// Records the most recent dictation so the panel can show it with a copy button.
    func setLastDictation(_ text: String) {
        statusPanelVM.lastDictation = text
    }

    /// Called every second while recording to update the live timer.
    func incrementRecordingSeconds() {
        statusPanelVM.recordingSeconds += 1
    }

    // MARK: - Blink animation

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        blinkPhase = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // Timer fires on main thread — re-enter main actor isolation explicitly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkPhase.toggle()
                self.statusItem?.button?.alphaValue = self.blinkPhase ? 1.0 : 0.3
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        statusItem?.button?.alphaValue = 1.0
    }

    private func updateIcon(for state: AppState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            button.image = Self.brandIdleImage()
            button.contentTintColor = nil
        case .needsAPIKey:
            button.image = NSImage(systemSymbolName: "key.fill",
                                   accessibilityDescription: "Voiceflow — API-Key fehlt")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill",
                                   accessibilityDescription: "Voiceflow — Aufnahme")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "Voiceflow — Verarbeitung")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .retrying:
            button.image = NSImage(systemSymbolName: "arrow.clockwise.circle",
                                   accessibilityDescription: "Voiceflow — Neuer Versuch")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        case .success, .successWithClipboard:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                   accessibilityDescription: "Voiceflow — Fertig")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
        case .successWithRawFallback:
            button.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill",
                                   accessibilityDescription: "Voiceflow — Rohtext eingefügt")
            button.image?.isTemplate = false
            button.contentTintColor = .systemYellow
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "Voiceflow — Fehler")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
    }

    // MARK: - Click Handling

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showUtilityMenu(relativeTo: sender)
        } else {
            togglePopover(button: sender)
        }
    }

    private func togglePopover(button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Right-Click Utility Menu

    private func showUtilityMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Einstellungen…",
            action: #selector(handleSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(
            title: "Verlauf öffnen",
            action: #selector(handleHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Nach Updates suchen…",
            action: #selector(handleCheckForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Voiceflow beenden",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Temporarily attach the menu so it pops up from the status bar button
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Remove the menu immediately after so left-clicks still show the popover
        statusItem?.menu = nil
    }

    @objc private func handleCheckForUpdates() { delegate?.menuBarDidRequestCheckForUpdates() }
    @objc private func handleSettings()        { delegate?.menuBarDidRequestSettings() }
    @objc private func handleHistory()         { delegate?.menuBarDidRequestHistory() }
    @objc private func handleQuit()            { delegate?.menuBarDidRequestQuit() }

    // MARK: - Cleanup

    deinit {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
