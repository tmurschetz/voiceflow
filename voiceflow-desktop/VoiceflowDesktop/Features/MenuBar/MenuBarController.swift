import AppKit
import SwiftUI

/// Delegate protocol so AppDelegate can respond to menu bar actions
/// without MenuBarController needing to import AppDelegate.
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestSettings()
    func menuBarDidRequestSignOut()
    func menuBarDidRequestQuit()
}

/// Owns the NSStatusItem (menu bar icon) and the popover panel.
/// Updates the icon appearance to reflect the current AppState.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let statusPanelVM = StatusPanelViewModel()
    private weak var delegate: MenuBarControllerDelegate?

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
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voiceflow")
        button.image?.isTemplate = true  // Adapts to light/dark menu bar automatically
        button.action = #selector(statusButtonClicked)
        button.target = self
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
        pop.behavior = .transient  // Closes when user clicks elsewhere
        pop.contentViewController = NSHostingController(rootView: panel)
        self.popover = pop
    }

    // MARK: - State Updates

    /// Called by AppDelegate whenever app state changes.
    func update(state: AppState, profile: UserProfile?, settings: AppSettings?) {
        statusPanelVM.state = state
        if let profile { statusPanelVM.profile = profile }
        if let settings { statusPanelVM.settings = settings }
        updateIcon(for: state)
    }

    private func updateIcon(for state: AppState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voiceflow — Idle")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Voiceflow — Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Voiceflow — Processing")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .success:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Voiceflow — Done")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Voiceflow — Error")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        case .blocked:
            button.image = NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: "Voiceflow — Blocked")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
    }

    // MARK: - Popover Toggle

    @objc private func statusButtonClicked() {
        guard let button = statusItem?.button, let popover else { return }
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

    // MARK: - Cleanup

    deinit {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
