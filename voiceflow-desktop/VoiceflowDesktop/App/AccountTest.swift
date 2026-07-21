import AppKit
import Foundation

/// Headless end-to-end test of the managed-account flow against a running
/// accounts service (normally `wrangler dev` with TEST_MODE):
///
///   Voiceflow --accounttest http://localhost:8787 <adminToken>
///
/// Exercises the REAL AccountService code (registration, polling, one-time key
/// pickup, revocation kill switch) with an **in-memory store** — the user's
/// actual Keychain is never touched. Exits 0 on success.
@MainActor
enum AccountTest {

    private static var passed = 0, failed = 0

    private static func check(_ name: String, _ ok: Bool, detail: String = "") {
        if ok { passed += 1; print("  ✅ \(name)") }
        else  { failed += 1; print("  ❌ \(name)  \(detail)") }
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--accounttest") else { return false }
        guard args.indices.contains(i + 2) else {
            print("Usage: --accounttest <serviceURL> <adminToken>")
            exit(2)
        }
        let base = args[i + 1], adminToken = args[i + 2]

        Task { @MainActor in
            let ok = await run(base: base, adminToken: adminToken)
            exit(ok ? 0 : 1)
        }
        return true
    }

    static func run(base: String, adminToken: String) async -> Bool {
        print("\n========== Account-E2E gegen \(base) ==========\n")

        // In-memory store — the real Keychain stays untouched.
        var memToken: String?
        var memKey: String?
        let store = AccountService.Store(
            getDeviceToken: { memToken },
            setDeviceToken: { memToken = $0 },
            installAPIKey:  { memKey = $0 },
            removeAPIKey:   { memKey = nil },
            hasAPIKey:      { memKey != nil }
        )
        // Managed/pending flags land in UserDefaults — restore afterwards.
        let defaults = UserDefaults.standard
        let savedManaged = defaults.bool(forKey: AccountService.managedFlagKey)
        let savedPending = defaults.bool(forKey: AccountService.pendingFlagKey)
        defer {
            defaults.set(savedManaged, forKey: AccountService.managedFlagKey)
            defaults.set(savedPending, forKey: AccountService.pendingFlagKey)
        }
        defaults.set(false, forKey: AccountService.managedFlagKey)
        defaults.set(false, forKey: AccountService.pendingFlagKey)

        let service = AccountService(store: store, baseURL: { base })

        // 1. Register
        let requested = await service.requestAccess(name: "E2E Test", email: "e2e@test.local")
        check("Registrierung angenommen", requested, detail: service.lastError ?? "")
        check("Phase = pending", service.phase == .pending)
        check("Gerätetoken erzeugt (64 hex)", memToken?.count == 64)

        guard let deviceToken = memToken else { return finish() }

        // 2. Poll while pending
        _ = await service.pollOnce()
        check("Poll vor Freigabe bleibt pending", service.phase == .pending)
        check("Noch kein Key installiert", memKey == nil)

        // 3. Approve via admin API (simulating Thomas)
        let approved = await admin(base: base, token: adminToken, action: "approve", deviceToken: deviceToken)
        check("Admin-Freigabe ok", approved)

        // 4. Poll → key must arrive exactly once, straight into the store
        _ = await service.pollOnce()
        check("Phase = active nach Freigabe", service.phase == .active)
        check("Key installiert (sk-…)", memKey?.hasPrefix("sk-") == true)
        check("Managed-Flag gesetzt", service.isManaged)

        // 5. Second poll: server must not deliver the key again
        let keyBefore = memKey
        _ = await service.pollOnce()
        check("Kein zweiter Key ausgeliefert", memKey == keyBefore)

        // 6. Revoke (kill switch) → next poll removes the local key
        let revoked = await admin(base: base, token: adminToken, action: "revoke", deviceToken: deviceToken)
        check("Admin-Widerruf ok", revoked)
        _ = await service.pollOnce()
        check("Phase = revoked", service.phase == .revoked)
        check("Lokaler Key entfernt (Kill-Switch)", memKey == nil)
        check("Managed-Flag entfernt", !service.isManaged)

        return finish()
    }

    private static func finish() -> Bool {
        print("\n========== Ergebnis: \(passed) bestanden, \(failed) fehlgeschlagen ==========\n")
        return failed == 0
    }

    /// Minimal admin client used only by this test (the app itself has no
    /// admin capabilities — approvals happen on the /admin web page).
    private static func admin(base: String, token: String, action: String, deviceToken: String) async -> Bool {
        guard let url = URL(string: "\(base)/admin/\(action)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
