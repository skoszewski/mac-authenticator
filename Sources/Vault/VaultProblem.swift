import Foundation

/// An error that states its own problem, for the errors of the layers above the library.
public protocol VaultProblemConvertible {
    var vaultProblem: VaultProblem { get }
}

/// What is wrong with a Vault, in words: the title says what, the detail what happened, and the
/// suggestion what to do about it.
public struct VaultProblem: Equatable, Sendable {
    public enum Kind: Sendable {
        case address
        case network
        case tls
        case notSignedIn
        case denied
        case credential
        case server
        case response
        case other
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var suggestion: String

    public init(kind: Kind, title: String, detail: String, suggestion: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
    }

    /// The problem as one text, to copy into a report.
    public var report: String {
        "\(title)\n\(detail)\n\(suggestion)"
    }

    /// The problem of an error; the method of the vault, when known, words what to do about a refused token.
    public init(_ error: Error, method: AuthMethod? = nil) {
        switch error {
        case let error as VaultProblemConvertible:
            self = error.vaultProblem
        case let error as VaultError:
            self = Self.problem(of: error, method: method)
        case let error as URLError:
            self = Self.problem(of: error)
        default:
            self = VaultProblem(kind: .other, title: "The operation failed", detail: error.localizedDescription,
                                suggestion: "Try again. If it keeps failing, copy the details into a report.")
        }
    }

    private static func problem(of error: VaultError, method: AuthMethod?) -> VaultProblem {
        switch error {
        case let .badAddress(address):
            return VaultProblem(kind: .address, title: "The address is not usable",
                                detail: "\"\(address)\" is not a Vault address.",
                                suggestion: "Use the form https://vault.example.com:8200.")
        case let .http(status, messages):
            let said = messages.isEmpty ? "Vault gave no message." : messages.joined(separator: "; ")
            return problem(status: status, said: said, method: method)
        case let .badResponse(what):
            return VaultProblem(kind: .response, title: "The answer is not from a Vault",
                                detail: "The answer could not be read as \(what).",
                                suggestion: "Check that the address and the port are those of the Vault API, not of a web page or a proxy.")
        case .notSignedIn:
            return VaultProblem(kind: .notSignedIn, title: "Not signed in",
                                detail: "No sign-in is active, and an OIDC vault signs in interactively when it has no token, or when its token ends.",
                                suggestion: "Sign in to the vault.")
        case let .oidc(message):
            return VaultProblem(kind: .denied, title: "The OIDC sign-in failed", detail: message,
                                suggestion: "Sign in again; check the OIDC role and its redirect URI.")
        case let .keyExists(name):
            return VaultProblem(kind: .other, title: "The key exists", detail: "The vault holds a key named \(name).",
                                suggestion: "Choose another name.")
        case let .noSecret(name):
            return VaultProblem(kind: .server, title: "The secret does not exist", detail: "The vault holds no secret named \(name).",
                                suggestion: "Check the KV version, the mount and the secret name.")
        case let .secretDeleted(name):
            return VaultProblem(kind: .server, title: "The secret was deleted", detail: "The latest version of the secret \(name) is deleted or destroyed.",
                                suggestion: "Undelete the version in Vault, or choose another secret.")
        case let .writeLost(name):
            return VaultProblem(kind: .server, title: "The secret was changed by another writer",
                                detail: "The field was not kept in \(name): another writer replaced the secret while it was written.",
                                suggestion: "Try again.")
        case let .missingField(field, secret):
            return VaultProblem(kind: .other, title: "The secret has no such field", detail: "The secret \(secret) holds no field named \(field).",
                                suggestion: "Check the name of the field.")
        case let .unsupportedKey(reason):
            return VaultProblem(kind: .other, title: "The vault cannot keep this key", detail: reason,
                                suggestion: "Use a key of 6 or 8 digits.")
        }
    }

    private static func problem(status: Int, said: String, method: AuthMethod?) -> VaultProblem {
        let again: String
        switch method {
        case .token:
            again = "Replace the token"
        case .userpass, .approle:
            again = "Log in again"
        case .oidc:
            again = "Sign in again"
        case nil:
            again = "Authenticate again"
        }
        switch status {
        case 400:
            return VaultProblem(kind: .server, title: "Vault refused the request", detail: said,
                                suggestion: "Check the key name and the vault's address, mounts and method; Vault's message says what is wrong.")
        case 403:
            return VaultProblem(kind: .denied, title: "Vault denied the access", detail: said,
                                suggestion: "The token may have ended, or its policy lacks this access. \(again), or ask for the policy.")
        case 404:
            return VaultProblem(kind: .server, title: "Vault does not know the path", detail: said,
                                suggestion: "Check the mount of the TOTP engine and the mount of the authentication method.")
        case 429:
            return VaultProblem(kind: .server, title: "Vault is busy", detail: said,
                                suggestion: "Wait and try again.")
        case 503:
            return VaultProblem(kind: .server, title: "Vault is sealed or in standby", detail: said,
                                suggestion: "Unseal Vault, or use the address of the active node.")
        default:
            return VaultProblem(kind: .server, title: "Vault answered \(status)", detail: said,
                                suggestion: status >= 500 ? "The server has a problem; try again later, and look at its log."
                                                          : "Check the vault's address, mounts and method.")
        }
    }

    private static func problem(of error: URLError) -> VaultProblem {
        let host = error.failingURL?.host ?? "the vault"
        switch error.code {
        case .cancelled:
            return VaultProblem(kind: .other, title: "The request was cancelled",
                                detail: "The request to the vault was cancelled before it ended.",
                                suggestion: "Run it again when you are ready.")
        case .cannotFindHost, .dnsLookupFailed:
            return VaultProblem(kind: .network, title: "The vault's name does not resolve",
                                detail: "The name \(host) was not found.",
                                suggestion: "Check the address, the network and the VPN; try the IP address.")
        case .cannotConnectToHost:
            return VaultProblem(kind: .network, title: "Nothing answers at the vault's address",
                                detail: "The connection to \(host) was refused or blocked.",
                                suggestion: "Check the host and the port, that Vault runs, and any firewall or VPN. On a local network, macOS may also need to allow Mac Authenticator to reach the local network.")
        case .timedOut:
            return VaultProblem(kind: .network, title: "The vault did not answer in time",
                                detail: "\(host) did not answer before the time ran out.",
                                suggestion: "Check that the host is up and reachable, and the VPN.")
        case .notConnectedToInternet:
            return VaultProblem(kind: .network, title: "The network is down", detail: "This Mac is offline.",
                                suggestion: "Connect to the network or the VPN.")
        case .networkConnectionLost:
            return VaultProblem(kind: .network, title: "The connection was lost",
                                detail: "The connection to \(host) broke while it was in use.",
                                suggestion: "Try again; check the network and the server.")
        case .secureConnectionFailed:
            return VaultProblem(kind: .tls, title: "The secure connection failed",
                                detail: "A TLS connection to \(host) could not be made.",
                                suggestion: "Check that the address is https and the port serves TLS; a plain HTTP port fails this way when asked for https.")
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return VaultProblem(kind: .tls, title: "The vault's certificate is not trusted",
                                detail: "The certificate of \(host) was not issued by an authority this Mac trusts.",
                                suggestion: "Trust the issuing CA in Keychain Access, and make the server send its intermediate certificates.")
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return VaultProblem(kind: .tls, title: "The vault's certificate is expired or not yet valid",
                                detail: "The dates of the certificate of \(host) do not include today.",
                                suggestion: "Renew the certificate; check the date of this Mac.")
        case .clientCertificateRequired, .clientCertificateRejected:
            return VaultProblem(kind: .tls, title: "The vault wants a client certificate",
                                detail: "\(host) requires a client certificate, which the app does not send.",
                                suggestion: "Use a listener that does not require one.")
        case .appTransportSecurityRequiresSecureConnection:
            return VaultProblem(kind: .tls, title: "Plain HTTP is blocked", detail: "The system refused an HTTP connection.",
                                suggestion: "Use an https:// address.")
        case .badServerResponse, .cannotParseResponse:
            return VaultProblem(kind: .response, title: "The answer is not from a Vault",
                                detail: "\(host) gave an answer that is not valid HTTP.",
                                suggestion: "Check that the address and the port are those of the Vault API.")
        case .badURL, .unsupportedURL:
            return VaultProblem(kind: .address, title: "The address is not usable",
                                detail: "The system cannot make a request to that address.",
                                suggestion: "Use the form https://vault.example.com:8200.")
        default:
            return VaultProblem(kind: .network, title: "The connection failed", detail: error.localizedDescription,
                                suggestion: "Check the address and the network, and try again.")
        }
    }
}
