import Foundation
import Network

/// The result of one step of a connection test.
public struct VaultCheck: Equatable, Sendable {
    public enum Outcome: Sendable {
        case passed
        case warning
        case failed
        case skipped
    }

    public var step: String
    public var outcome: Outcome
    public var message: String
    /// Why the step failed or warns, with what to do.
    public var problem: VaultProblem?

    public init(step: String, outcome: Outcome, message: String, problem: VaultProblem?) {
        self.step = step
        self.outcome = outcome
        self.message = message
        self.problem = problem
    }
}

/// Tests the connection to a Vault step by step: the address, the server, the authentication and the
/// TOTP engine. It keeps no token and touches no session.
public enum VaultDiagnostics {
    /// Runs the steps in order, stopping after a step that fails; the credential is the token,
    /// the password or the SecretID of the configured method.
    public static func run(configuration: VaultConfiguration, credential: String?) async -> [VaultCheck] {
        var checks: [VaultCheck] = []
        let client = VaultClient(configuration: configuration)

        // Address
        do {
            let request = try client.makeRequest("GET", "sys/health")
            let plain = request.url?.scheme?.lowercased() == "http"
            let local = plain ? await resolvesToLoopback(request.url?.host ?? "") : false
            if plain, !local {
                checks.append(VaultCheck(step: "Address", outcome: .warning,
                                         message: "The address uses plain HTTP; the credential and the codes cross the network unencrypted.",
                                         problem: nil))
            } else {
                checks.append(VaultCheck(step: "Address", outcome: .passed,
                                         message: configuration.address.trimmingCharacters(in: .whitespaces), problem: nil))
            }
        } catch {
            checks.append(VaultCheck(step: "Address", outcome: .failed, message: "The address cannot be used.",
                                     problem: VaultProblem(error)))
            return checks
        }

        // Server
        do {
            let status = try await client.healthStatus()
            switch status {
            case 200:
                checks.append(VaultCheck(step: "Server", outcome: .passed, message: "Vault is active and unsealed.", problem: nil))
            case 429, 472, 473:
                checks.append(VaultCheck(step: "Server", outcome: .warning, message: "Vault answers as a standby node.", problem: nil))
            case 501:
                checks.append(VaultCheck(step: "Server", outcome: .failed, message: "Vault is not initialized.",
                                         problem: VaultProblem(VaultError.http(status: status, messages: []))))
                return checks
            case 503:
                checks.append(VaultCheck(step: "Server", outcome: .failed, message: "Vault is sealed.",
                                         problem: VaultProblem(VaultError.http(status: status, messages: []))))
                return checks
            default:
                checks.append(VaultCheck(step: "Server", outcome: .warning, message: "Vault's health check answered \(status).", problem: nil))
            }
        } catch {
            checks.append(VaultCheck(step: "Server", outcome: .failed, message: "The server could not be reached.",
                                     problem: VaultProblem(error)))
            return checks
        }

        // Authentication: a token is checked, a password or an AppRole is logged in, OIDC is not tested.
        let step: String
        switch configuration.authMethod {
        case .token:
            step = "Token"
        case .userpass, .approle:
            step = "Login"
        case .oidc:
            step = "Authentication"
        }
        let token: VaultToken?
        do {
            token = try await VaultClient.signIn(configuration: configuration, credential: credential)
            switch (configuration.authMethod, token) {
            case let (.token, token?):
                let end = token.expires.map { "until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "and has no end"
                checks.append(VaultCheck(step: step, outcome: .passed, message: "The token is valid \(end).", problem: nil))
            case (.userpass, _):
                checks.append(VaultCheck(step: step, outcome: .passed,
                                         message: "Vault issued a token to the user \(configuration.username ?? "").", problem: nil))
            case (.approle, _):
                checks.append(VaultCheck(step: step, outcome: .passed, message: "Vault issued a token to the AppRole.", problem: nil))
            default:
                checks.append(VaultCheck(step: step, outcome: .skipped,
                                         message: "Not tested: an OIDC vault signs in interactively.", problem: nil))
            }
        } catch {
            let message = configuration.authMethod == .token ? "Vault did not accept the token." : "Vault refused the login."
            checks.append(VaultCheck(step: step, outcome: .failed, message: message,
                                     problem: VaultProblem(error, method: configuration.authMethod)))
            return checks
        }

        // TOTP engine
        guard let token else {
            checks.append(VaultCheck(step: "TOTP engine", outcome: .skipped, message: "Not tested: there is no token.", problem: nil))
            return checks
        }
        do {
            let keys = try await VaultClient(configuration: configuration, token: token.token).listKeys()
            if keys.isEmpty {
                checks.append(VaultCheck(step: "TOTP engine", outcome: .warning,
                                         message: "The engine lists no keys; the mount \(configuration.totpMount) may be wrong.",
                                         problem: nil))
            } else {
                checks.append(VaultCheck(step: "TOTP engine", outcome: .passed,
                                         message: keys.count == 1 ? "1 key is listed." : "\(keys.count) keys are listed.", problem: nil))
            }
        } catch let error as VaultError where error.isDenied {
            checks.append(VaultCheck(step: "TOTP engine", outcome: .warning,
                                     message: "The policy does not allow listing the keys.",
                                     problem: VaultProblem(error, method: configuration.authMethod)))
        } catch {
            checks.append(VaultCheck(step: "TOTP engine", outcome: .failed, message: "The keys could not be listed.",
                                     problem: VaultProblem(error)))
        }
        return checks
    }

    /// Whether the host name resolves to loopback addresses alone; false when it does not resolve.
    static func resolvesToLoopback(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                return false
            }
            defer {
                freeaddrinfo(first)
            }
            var found = false
            for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let address = entry.pointee.ai_addr else {
                    return false
                }
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    guard UInt32(bigEndian: raw.s_addr) >> 24 == 127 else {
                        return false
                    }
                case AF_INET6:
                    let raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    guard IPv6Address(withUnsafeBytes(of: raw) { Data($0) })?.isLoopback == true else {
                        return false
                    }
                default:
                    return false
                }
                found = true
            }
            return found
        }.value
    }
}
