import AppKit
import SwiftUI

/// Delegate protocol so AppDelegate can respond to menu bar actions
/// without MenuBarController needing to import AppDelegate.
@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestSettings()
    func menuBarDidRequestSignOut()
    func menuBarDidRequestCheckForUpdates()
    func menuBarDidRequestQuit()
}

/// Owns the NSStatusItem (menu bar icon) and the popover panel.
///
/// Left-click  → toggles the status-panel popover.
/// Right-click → shows a utility NSMenu (Settings, Check for Updates, Sign Out, Quit).
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let statusPanelVM = StatusPanelViewModel()
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
            // Constrain to a tidy menu-bar size so the template renders crisply
            // regardless of the source PNG resolution.
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
            onSignOut: { [weak self] in
                self?.closePopover()
                self?.delegate?.menuBarDidRequestSignOut()
            }
        )

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 260, height: 320)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: panel)
        self.popover = pop
    }

    // MARK: - State Updates

    func update(state: AppState, profile: UserProfile?, settings: AppSettings?) {
        statusPanelVM.state = state
        if let profile  { statusPanelVM.profile  = profile  }
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
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill",
                                   accessibilityDescription: "Voiceflow — Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "Voiceflow — Processing")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .retrying:
            button.image = NSImage(systemSymbolName: "arrow.clockwise.circle",
                                   accessibilityDescription: "Voiceflow — Retrying")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        case .success, .successWithClipboard:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                   accessibilityDescription: "Voiceflow — Done")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
        case .successWithRawFallback:
            button.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill",
                                   accessibilityDescription: "Voiceflow — Server unavailable, raw text")
            button.image?.isTemplate = false
            button.contentTintColor = .systemYellow
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "Voiceflow — Error")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        case .blocked:
            button.image = NSImage(systemSymbolName: "lock.circle.fill",
                                   accessibilityDescription: "Voiceflow — Blocked")
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

    /// Shown on right-click. Provides quick access to utility actions without
    /// opening the full status-panel popover.
    private func showUtilityMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(handleCheckForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let signOutItem = NSMenuItem(
            title: "Sign Out",
            action: #selector(handleSignOut),
            keyEquivalent: ""
        )
        signOutItem.target = self
        menu.addItem(signOutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Voiceflow",
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
    @objc private func handleSettings()         { delegate?.menuBarDidRequestSettings() }
    @objc private func handleSignOut()          { delegate?.menuBarDidRequestSignOut() }
    @objc private func handleQuit()             { delegate?.menuBarDidRequestQuit() }

    // MARK: - Cleanup

    deinit {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
