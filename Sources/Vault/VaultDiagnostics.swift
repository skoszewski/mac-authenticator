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

/// Tests the connection to a Vault step by step: the address, the server, the sign-in and the
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
                checks.append(VaultCheck(step: "Address", outcome: .passed, message: request.url?.absoluteString ?? "", problem: nil))
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

        // Sign-in
        let token: VaultToken?
        do {
            token = try await signIn(configuration, credential)
            checks.append(VaultCheck(step: "Sign-in", outcome: token == nil ? .skipped : .passed,
                                     message: token == nil ? "OIDC signs in in the browser, from the vault's page."
                                                           : "Signed in with the \(configuration.authMethod.rawValue) method.",
                                     problem: nil))
        } catch {
            checks.append(VaultCheck(step: "Sign-in", outcome: .failed, message: "The sign-in failed.",
                                     problem: VaultProblem(error)))
            return checks
        }

        // TOTP engine
        guard let token else {
            checks.append(VaultCheck(step: "TOTP engine", outcome: .skipped, message: "Needs a sign-in.", problem: nil))
            return checks
        }
        do {
            let keys = try await VaultClient(configuration: configuration, token: token.token).listKeys()
            if keys.isEmpty {
                checks.append(VaultCheck(step: "TOTP engine", outcome: .warning,
                                         message: "The engine lists no keys; the mount \(configuration.totpMount) may be wrong.",
                                         problem: nil))
            } else {
                checks.append(VaultCheck(step: "TOTP engine", outcome: .passed, message: "\(keys.count) keys are listed.", problem: nil))
            }
        } catch let error as VaultError where error.isDenied {
            checks.append(VaultCheck(step: "TOTP engine", outcome: .warning,
                                     message: "The policy does not allow listing the keys; their names can be typed.",
                                     problem: VaultProblem(error)))
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

    /// A setting or credential the method needs and the form leaves empty.
    private struct Empty: Error, VaultProblemConvertible {
        let what: String

        var vaultProblem: VaultProblem {
            VaultProblem(kind: .credential, title: "\(what) is empty", detail: "The sign-in needs \(what.lowercased()).",
                         suggestion: "Enter it in the vault's settings.")
        }
    }

    /// The token of a sign-in with the configured method; nil for OIDC, which needs the browser.
    private static func signIn(_ configuration: VaultConfiguration, _ credential: String?) async throws -> VaultToken? {
        func required(_ value: String?, _ what: String) throws -> String {
            guard let value, !value.isEmpty else {
                throw Empty(what: what)
            }
            return value
        }
        let client = VaultClient(configuration: configuration)
        switch configuration.authMethod {
        case .token:
            return try await VaultClient(configuration: configuration, token: try required(credential, "The token"))
                .lookupSelf()
        case .userpass:
            return try await client.loginUserpass(username: try required(configuration.username, "The user name"),
                                                  password: try required(credential, "The password"))
        case .approle:
            return try await client.loginAppRole(roleID: try required(configuration.roleID, "The RoleID"),
                                                 secretID: try required(credential, "The SecretID"))
        case .oidc:
            return nil
        }
    }
}
