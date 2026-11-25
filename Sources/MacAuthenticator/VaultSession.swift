import AppKit
import Observation
import OSLog
import Vault

/// A named Vault connection; the keychain item of the profile is labelled with its name.
struct VaultProfile: Identifiable, Equatable {
    var id: UUID
    var name: String
    var configuration: VaultConfiguration
}

/// Why the session cannot sign in.
enum SessionError: LocalizedError {
    case missingCredential
    case missingSetting(String)
    case invalidSetting(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSetting(name):
            return "The Vault setting \(name) is not valid."
        case .missingCredential:
            return "No Vault credential is stored."
        case let .missingSetting(name):
            return "The Vault setting \(name) is empty."
        }
    }
}

extension SessionError: VaultProblemConvertible {
    var vaultProblem: VaultProblem {
        switch self {
        case .missingCredential:
            return VaultProblem(kind: .credential, title: "No credential is stored", detail: "The keychain holds no token, password or SecretID for this vault.",
                                suggestion: "Store a credential for the vault.")
        case let .missingSetting(name):
            return VaultProblem(kind: .address, title: "A setting is empty", detail: "\(name) is empty.",
                                suggestion: "Give the vault a value for it.")
        case let .invalidSetting(name):
            return VaultProblem(kind: .address, title: "A setting is not valid", detail: "\(name) is not valid.",
                                suggestion: "Give the vault a valid value for it.")
        }
    }
}

extension Keychain.Failure: VaultProblemConvertible {
    var vaultProblem: VaultProblem {
        VaultProblem(kind: .credential, title: "The keychain refused", detail: errorDescription ?? "The keychain call failed.",
                     suggestion: "Allow Mac Authenticator to use the keychain item, or store the credential again.")
    }
}

/// A Vault connection: a named profile, kept in the keychain with its credential, and the token of
/// the current token, which for OIDC is also kept in the keychain.
@MainActor
@Observable
final class VaultSession {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(until: Date?)
        case failed(VaultProblem)
    }

    private static let log = Logger(subsystem: "pl.waw.koszewscy.MacAuthenticator", category: "vault")

    private(set) var profile: VaultProfile
    private(set) var status: Status = .signedOut
    /// When the last call to the vault ended, in success or in failure.
    private(set) var lastAttempt: Date?
    /// Called once when a vault that worked fails, until it works again.
    @ObservationIgnored var onProblem: ((VaultSession, VaultProblem) -> Void)?
    @ObservationIgnored private var worked = false
    @ObservationIgnored private(set) var token: VaultToken?
    @ObservationIgnored private var signInTask: Task<Void, Error>?
    @ObservationIgnored private var signInWindow: OIDCSignInWindow?

    /// An OIDC profile takes up the token kept in the keychain, unless it has ended.
    init(profile: VaultProfile) {
        self.profile = profile
        guard profile.configuration.authMethod == .oidc, let kept = try? Keychain.vaultToken(of: profile.id) else {
            return
        }
        if let expires = kept.expires, expires.timeIntervalSinceNow <= 5 {
            keep(nil)
        } else {
            token = kept
            status = .signedIn(until: kept.expires)
        }
    }

    var configuration: VaultConfiguration {
        profile.configuration
    }

    /// Takes the new name and settings of the profile, and signs out.
    func update(_ profile: VaultProfile) {
        self.profile = profile
        signOut()
    }

    /// Drops the token, and the one kept in the keychain, and closes a sign-in window that is open.
    func signOut() {
        signInWindow?.cancel()
        keep(nil)
        worked = false
        status = .signedOut
    }

    /// Makes the token the current one, or none; an OIDC token is kept in the keychain, and a
    /// token dropped is forgotten there. A keychain that refuses is logged, and the token still works.
    private func keep(_ token: VaultToken?) {
        self.token = token
        guard token == nil || configuration.authMethod == .oidc else {
            return
        }
        do {
            if let token {
                try Keychain.saveVaultToken(token, of: profile.id)
            } else {
                try Keychain.deleteVaultToken(of: profile.id)
            }
        } catch {
            Self.log.error("\(self.profile.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records a failed call: the status shows its problem, and a vault that worked is reported once.
    private func report(_ error: Error) {
        guard !(error is CancellationError) else {
            return
        }
        let problem = VaultProblem(error, method: configuration.authMethod)
        lastAttempt = Date()
        guard status != .failed(problem) else {
            return
        }
        status = .failed(problem)
        Self.log.error("\(self.profile.name, privacy: .public): \(problem.title, privacy: .public)")
        if worked {
            worked = false
            onProblem?(self, problem)
        }
    }

    /// Records a call that worked; a failed status returns to signed in.
    private func succeeded() {
        worked = true
        lastAttempt = Date()
        if case .failed = status {
            status = .signedIn(until: token?.expires)
        }
    }

    /// Signs in with the configured method; calls made while a sign-in runs wait for it.
    func signIn() async throws {
        if let signInTask {
            return try await signInTask.value
        }
        let task = Task { try await performSignIn() }
        signInTask = task
        defer {
            signInTask = nil
        }
        try await task.value
    }

    private func performSignIn() async throws {
        status = .signingIn
        do {
            let token = try await login(configuration)
            keep(token)
            status = .signedIn(until: token.expires)
            succeeded()
        } catch is CancellationError {
            status = .signedOut
            throw CancellationError()
        } catch {
            report(error)
            throw error
        }
    }

    private func login(_ configuration: VaultConfiguration) async throws -> VaultToken {
        func setting(_ value: String?, _ name: String) throws -> String {
            guard let value, !value.isEmpty else {
                throw SessionError.missingSetting(name)
            }
            return value
        }
        func credential() throws -> String {
            guard let credential = try Keychain.vaultCredential(of: profile.id) else {
                throw SessionError.missingCredential
            }
            return credential
        }

        let client = VaultClient(configuration: configuration)
        switch configuration.authMethod {
        case .token:
            return try await VaultClient(configuration: configuration, token: try credential()).lookupSelf()
        case .userpass:
            return try await client.loginUserpass(username: try setting(configuration.username, "Username"),
                                                  password: try credential())
        case .approle:
            return try await client.loginAppRole(roleID: try setting(configuration.roleID, "RoleID"),
                                                 secretID: try credential())
        case .oidc:
            return try await oidcLogin(configuration, client)
        }
    }

    /// Signs in in a window of the app, which takes the redirect of the identity provider itself.
    private func oidcLogin(_ configuration: VaultConfiguration, _ client: VaultClient) async throws -> VaultToken {
        let clientNonce = UUID().uuidString
        let url = try await client.oidcAuthURL(role: configuration.oidcRole, redirectURI: configuration.oidcRedirectURI,
                                               clientNonce: clientNonce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let state = items.first(where: { $0.name == "state" })?.value,
              let nonce = items.first(where: { $0.name == "nonce" })?.value,
              let redirect = URL(string: configuration.oidcRedirectURI) else {
            throw VaultError.oidc("Vault's authorisation URL holds no state or nonce.")
        }
        let window = OIDCSignInWindow()
        signInWindow = window
        defer {
            signInWindow = nil
        }
        let callback = try await window.run(url: url, redirect: redirect, title: "Sign in to \(profile.name)")
        if let error = callback.error {
            throw VaultError.oidc(error)
        }
        guard let code = callback.code, callback.state == state else {
            throw VaultError.oidc("The identity provider's answer does not belong to this sign-in.")
        }
        return try await client.oidcCallback(state: state, nonce: nonce, code: code, clientNonce: clientNonce)
    }

    /// The token to use: the current one, renewed when half of its lease is gone, or a new
    /// sign-in. An OIDC sign-in is never started here.
    private func validToken() async throws -> VaultToken {
        if let current = token, let expires = current.expires {
            let left = expires.timeIntervalSinceNow
            if left <= 5 {
                keep(nil)
            } else if current.renewable, let lease = current.lease, left < lease / 2,
                      let renewed = try? await VaultClient(configuration: configuration, token: current.token).renewSelf() {
                keep(renewed)
                status = .signedIn(until: renewed.expires)
            }
        }
        if let token {
            return token
        }
        guard configuration.authMethod != .oidc else {
            status = .signedOut
            throw VaultError.notSignedIn
        }
        try await signIn()
        guard let token else {
            throw VaultError.notSignedIn
        }
        return token
    }

    /// Runs a call with a valid token, and records its outcome in the status.
    func authorized<T: Sendable>(_ call: @Sendable (VaultClient) async throws -> T) async throws -> T {
        do {
            let result = try await perform(call)
            succeeded()
            return result
        } catch {
            report(error)
            throw error
        }
    }

    /// A token Vault refuses is replaced once by a new sign-in, unless the token itself is the
    /// credential or the sign-in is OIDC.
    private func perform<T: Sendable>(_ call: @Sendable (VaultClient) async throws -> T) async throws -> T {
        let first = try await validToken()
        do {
            return try await call(VaultClient(configuration: configuration, token: first.token))
        } catch let error as VaultError where error.isDenied {
            keep(nil)
            switch configuration.authMethod {
            case .userpass, .approle:
                try await signIn()
                guard let second = token else {
                    throw VaultError.notSignedIn
                }
                return try await call(VaultClient(configuration: configuration, token: second.token))
            case .oidc:
                status = .signedOut
                throw VaultError.notSignedIn
            case .token:
                throw error
            }
        }
    }
}
