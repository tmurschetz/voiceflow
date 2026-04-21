import SwiftUI

/// App entry point.
/// LSUIElement=YES in Info.plist removes the Dock icon — we run as a menu bar utility.
@main
struct VoiceflowDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — the app lives entirely in the menu bar.
        // Settings window is opened on demand from the menu bar.
        Settings {
            EmptyView()
        }
    }
}
