import Foundation

/// Client for the Voiceflow accounts service (voiceflow-backend/) — managed
/// access for friends & colleagues ("Variante B").
///
/// The service is contacted ONLY for registration, approval polling and the
/// one-time key pickup. Dictation traffic never touches it — after activation
/// the app talks straight to OpenAI, exactly like bring-your-own-key mode.
///
/// Security invariants on this side:
///   - The delivered key goes straight into the macOS Keychain and is never
///     displayed anywhere (Settings shows only "verwaltet").
///   - The device token (256-bit random, generated here) is the only credential
///     towards the service; it also lives in the Keychain.
///   - A remote revoke removes the local key on the next poll (kill switch).
@MainActor
final class AccountService: ObservableObject {

    static let shared = AccountService()

    // MARK: - Phase

    enum Phase: String {
        case none       // never registered (or registration unknown/expired)
        case pending    // registered, waiting for Thomas's approval
        case active     // managed key installed and in use
        case denied     // Thomas declined
        case revoked    // access was revoked remotely; local key removed
    }

    @Published private(set) var phase: Phase = .none
    /// Human-readable info for the last error (shown in the wizard).
    @Published var lastError: String?

    /// Fired on every phase transition (AppDelegate updates the menu bar).
    var onPhaseChange: ((Phase) -> Void)?

    // MARK: - Storage abstraction
    // The E2E test (`--accounttest`) runs the full real flow with an in-memory
    // store so it never touches the user's actual Keychain.

    struct Store {
        var getDeviceToken: () -> String?
        var setDeviceToken: (String?) -> Void
        var installAPIKey: (String) -> Void
        var removeAPIKey: () -> Void
        var hasAPIKey: () -> Bool

        static let real = Store(
            getDeviceToken: { KeychainStore.accountDeviceToken },
            setDeviceToken: { KeychainStore.accountDeviceToken = $0 },
            installAPIKey:  { KeychainStore.apiKey = $0 },
            removeAPIKey:   { KeychainStore.apiKey = nil },
            hasAPIKey:      { KeychainStore.hasAPIKey }
        )
    }

    private let store: Store
    private let baseURL: () -> String
    private var pollTask: Task<Void, Never>?

    static let managedFlagKey = "com.voiceflow.desktop.managedAccount"
    static let pendingFlagKey = "com.voiceflow.desktop.accountPending"

    init(store: Store = .real, baseURL: @escaping () -> String = { Config.accountServiceURL }) {
        self.store = store
        self.baseURL = baseURL
        restorePhase()
    }

    /// True when the installed key was provisioned by the service (not BYOK).
    var isManaged: Bool { UserDefaults.standard.bool(forKey: Self.managedFlagKey) }
    var isPending: Bool { phase == .pending }

    private func restorePhase() {
        if isManaged && store.hasAPIKey() {
            phase = .active
        } else if UserDefaults.standard.bool(forKey: Self.pendingFlagKey) {
            phase = .pending
        } else {
            phase = .none
        }
    }

    private func transition(to newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    // MARK: - Registration

    /// 256-bit random token, hex-encoded (64 chars) — matches the server's TOKEN_RE.
    nonisolated static func generateDeviceToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func requestAccess(name: String, email: String) async -> Bool {
        lastError = nil
        let token = store.getDeviceToken() ?? {
            let t = Self.generateDeviceToken()
            store.setDeviceToken(t)
            return t
        }()

        struct Body: Encodable { let name: String; let email: String; let deviceToken: String }
        do {
            let (data, http) = try await post(path: "/register",
                                              body: Body(name: name, email: email, deviceToken: token))
            if http.statusCode == 429 {
                lastError = "Zu viele Anfragen von diesem Netzwerk — bitte später nochmals versuchen."
                return false
            }
            guard http.statusCode == 200,
                  let resp = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
                lastError = "Der Dienst hat unerwartet geantwortet. Bitte später nochmals versuchen."
                return false
            }
            apply(resp)
            if phase == .pending || phase == .active {
                UserDefaults.standard.set(true, forKey: Self.pendingFlagKey)
                startPolling()
                return true
            }
            return false
        } catch {
            lastError = "Keine Verbindung zum Freigabe-Dienst. Bist du online?"
            return false
        }
    }

    // MARK: - Status polling

    struct StatusResponse: Decodable {
        let status: String
        let apiKey: String?
    }

    @discardableResult
    func pollOnce() async -> Phase {
        guard let token = store.getDeviceToken() else { return phase }
        guard var comps = URLComponents(string: baseURL() + "/status") else { return phase }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return phase }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let resp = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
            return phase   // network hiccup — keep current phase, retry later
        }
        apply(resp)
        return phase
    }

    /// Applies a server status to local state. Pure state machine — also used
    /// by the self-test with fixture responses.
    func apply(_ resp: StatusResponse) {
        switch resp.status {
        case "approved":
            if let key = resp.apiKey, !key.isEmpty {
                store.installAPIKey(key)
                UserDefaults.standard.set(true, forKey: Self.managedFlagKey)
                UserDefaults.standard.set(false, forKey: Self.pendingFlagKey)
                transition(to: .active)
            } else if store.hasAPIKey() {
                transition(to: .active)
            }
            // approved but no key and none installed → key was delivered to a
            // previous install; Thomas must "Key neu ausstellen". Stay pending.
        case "pending":
            transition(to: .pending)
        case "denied":
            UserDefaults.standard.set(false, forKey: Self.pendingFlagKey)
            transition(to: .denied)
        case "revoked":
            if isManaged {
                store.removeAPIKey()   // kill switch: key is dead at OpenAI anyway
                UserDefaults.standard.set(false, forKey: Self.managedFlagKey)
            }
            UserDefaults.standard.set(false, forKey: Self.pendingFlagKey)
            transition(to: .revoked)
        default:   // "unknown" — registration no longer exists server-side
            UserDefaults.standard.set(false, forKey: Self.pendingFlagKey)
            transition(to: .none)
        }
    }

    /// Polls every `interval` seconds while pending. Idempotent.
    func startPolling(interval: TimeInterval = 30) {
        guard pollTask == nil, phase == .pending else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase == .pending {
                _ = await self.pollOnce()
                if self.phase != .pending { break }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            self?.pollTask = nil
        }
    }

    /// Detach managed state (e.g. when the user removes the key or switches
    /// to their own key). Does not contact the server.
    func detach() {
        UserDefaults.standard.set(false, forKey: Self.managedFlagKey)
        UserDefaults.standard.set(false, forKey: Self.pendingFlagKey)
        pollTask?.cancel()
        pollTask = nil
        transition(to: .none)
    }

    // MARK: - HTTP helper

    private func post<B: Encodable>(path: String, body: B) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL() + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
