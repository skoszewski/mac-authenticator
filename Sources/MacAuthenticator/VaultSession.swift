import AppKit
import Observation
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
            return "No Vault credential is stored; enter it in Vault Settings."
        case let .missingSetting(name):
            return "The Vault setting \(name) is empty."
        }
    }
}

/// A Vault connection: a named profile, kept in the keychain with its credential, and the token of
/// the current sign-in, kept in memory alone.
@MainActor
@Observable
final class VaultSession {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(until: Date?)
        case failed(String)
    }

    private(set) var profile: VaultProfile
    private(set) var status: Status = .signedOut
    @ObservationIgnored private var token: VaultToken?
    @ObservationIgnored private var signInTask: Task<Void, Error>?
    @ObservationIgnored private var listener: OIDCCallbackListener?

    init(profile: VaultProfile) {
        self.profile = profile
    }

    var configuration: VaultConfiguration {
        profile.configuration
    }

    /// Takes the new name and settings of the profile, and signs out.
    func update(_ profile: VaultProfile) {
        self.profile = profile
        signOut()
    }

    /// Drops the token and stops a sign-in waiting for the browser.
    func signOut() {
        listener?.cancel()
        token = nil
        status = .signedOut
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
            self.token = token
            status = .signedIn(until: token.expires)
        } catch is CancellationError {
            status = .signedOut
            throw CancellationError()
        } catch {
            status = .failed(error.localizedDescription)
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

    /// Signs in through the browser: the identity provider redirects to a listener of this app.
    private func oidcLogin(_ configuration: VaultConfiguration, _ client: VaultClient) async throws -> VaultToken {
        let clientNonce = UUID().uuidString
        let listener = try OIDCCallbackListener(port: configuration.oidcPort)
        self.listener = listener
        defer {
            listener.cancel()
            self.listener = nil
        }
        try await listener.start()
        let url = try await client.oidcAuthURL(role: configuration.oidcRole, redirectURI: configuration.oidcRedirectURI,
                                               clientNonce: clientNonce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let state = items.first(where: { $0.name == "state" })?.value,
              let nonce = items.first(where: { $0.name == "nonce" })?.value else {
            throw VaultError.oidc("Vault's authorisation URL holds no state or nonce.")
        }
        NSWorkspace.shared.open(url)

        let callback = try await listener.callback()
        if let error = callback.error {
            throw VaultError.oidc(error)
        }
        guard let code = callback.code, callback.state == state else {
            throw VaultError.oidc("The browser's answer does not belong to this sign-in.")
        }
        return try await client.oidcCallback(state: state, nonce: nonce, code: code, clientNonce: clientNonce)
    }

    /// The token to use: the current one, renewed when half of its lease is gone, or a new
    /// sign-in. An OIDC sign-in is never started here.
    private func validToken() async throws -> VaultToken {
        if let current = token, let expires = current.expires {
            let left = expires.timeIntervalSinceNow
            if left <= 5 {
                token = nil
            } else if current.renewable, let lease = current.lease, left < lease / 2,
                      let renewed = try? await VaultClient(configuration: configuration, token: current.token).renewSelf() {
                token = renewed
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

    /// Runs a call with a valid token. A token Vault refuses is replaced once by a new sign-in,
    /// unless the token itself is the credential or the sign-in is through the browser.
    func authorized<T: Sendable>(_ call: @Sendable (VaultClient) async throws -> T) async throws -> T {
        let first = try await validToken()
        do {
            return try await call(VaultClient(configuration: configuration, token: first.token))
        } catch let error as VaultError where error.isDenied {
            token = nil
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
