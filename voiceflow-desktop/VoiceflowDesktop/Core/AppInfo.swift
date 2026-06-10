import Foundation

/// Read-only access to the app's version information from `Info.plist`.
///
/// macOS apps carry two version numbers:
///   - `CFBundleShortVersionString` — user-facing semantic version (e.g. `0.2.0`)
///   - `CFBundleVersion`            — internal build number (e.g. `2`)
///
/// We display them as `v0.2.0 (2)` in the Settings footer and the status panel
/// header so users (and bug reporters) can identify exactly which build they run.
enum AppInfo {

    /// Marketing version string (CFBundleShortVersionString). Falls back to "?"
    /// if the key is missing — should never happen in a properly built bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Build number (CFBundleVersion). Increments on every release build even
    /// when the marketing version stays the same.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Combined string suitable for UI display, e.g. `v0.2.0 (2)`.
    static var displayString: String { "v\(version) (\(build))" }
}
