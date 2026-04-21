import Foundation
import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {

    @Published var email: String = ""
    @Published var password: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let authService: AuthService
    private let onSuccess: () -> Void

    init(authService: AuthService, onSuccess: @escaping () -> Void) {
        self.authService = authService
        self.onSuccess = onSuccess
    }

    var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty && !isLoading
    }

    func signIn() async {
        guard canSubmit else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await authService.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            onSuccess()
        } catch let error as APIError {
            switch error {
            case .httpError(401, _):
                errorMessage = "Incorrect email or password."
            case .httpError(let code, _):
                errorMessage = "Sign in failed (HTTP \(code)). Please try again."
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
