import Foundation
import TOTP

/// How the app signs in to Vault.
public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case token
    case userpass
    case approle
    case oidc
}

/// Where Vault is and how to sign in to it; it holds no secret.
public struct VaultConfiguration: Codable, Equatable, Sendable {
    public var address: String
    public var namespace: String?
    public var totpMount: String
    public var authMethod: AuthMethod
    public var authMount: String
    public var username: String?
    public var roleID: String?
    public var oidcRole: String?
    public var oidcPort: Int

    public init(address: String, namespace: String? = nil, totpMount: String = "totp",
                authMethod: AuthMethod = .token, authMount: String? = nil, username: String? = nil,
                roleID: String? = nil, oidcRole: String? = nil, oidcPort: Int = 8250) {
        self.address = address
        self.namespace = namespace
        self.totpMount = totpMount
        self.authMethod = authMethod
        self.authMount = authMount ?? authMethod.rawValue
        self.username = username
        self.roleID = roleID
        self.oidcRole = oidcRole
        self.oidcPort = oidcPort
    }

    /// The redirect URI the OIDC role must allow.
    public var oidcRedirectURI: String {
        "http://localhost:\(oidcPort)/oidc/callback"
    }
}

/// Why a Vault call did not succeed.
public enum VaultError: LocalizedError, Equatable {
    case badAddress(String)
    case http(status: Int, messages: [String])
    case badResponse(String)
    case notSignedIn
    case oidc(String)
    case keyExists(String)
    case unsupportedKey(String)
    case noSecret(String)
    case missingField(field: String, secret: String)
    case secretDeleted(String)
    case writeLost(String)

    public var errorDescription: String? {
        switch self {
        case let .badAddress(address):
            return "\(address) is not a Vault address; use the form https://vault.example.com:8200."
        case let .http(status, messages):
            let detail = messages.isEmpty ? "no message" : messages.joined(separator: "; ")
            return "Vault answered \(status): \(detail)"
        case let .badResponse(what):
            return "Vault's answer could not be read: \(what)"
        case .notSignedIn:
            return "Not signed in to Vault."
        case let .oidc(message):
            return "The OIDC sign-in failed: \(message)"
        case let .keyExists(name):
            return "Vault holds a key named \(name) already; choose another name."
        case let .unsupportedKey(reason):
            return "Vault cannot keep this key: \(reason)"
        case let .noSecret(name):
            return "Vault holds no secret named \(name)."
        case let .missingField(field, secret):
            return "The secret \(secret) has no field named \(field)."
        case let .secretDeleted(name):
            return "The latest version of the secret \(name) is deleted."
        case let .writeLost(name):
            return "The secret \(name) was changed by another writer while the field was written."
        }
    }

    /// Whether Vault refused the token, so signing in again may help.
    public var isDenied: Bool {
        if case let .http(status, _) = self {
            return status == 403
        }
        return false
    }
}

/// A Vault token and when it ends; a token without an end has no expiry.
public struct VaultToken: Sendable, Equatable, Codable {
    public var token: String
    public var expires: Date?
    public var renewable: Bool
    /// The lease length, as Vault stated it, for judging when to renew.
    public var lease: TimeInterval?

    public init(token: String, expires: Date?, renewable: Bool, lease: TimeInterval? = nil) {
        self.token = token
        self.expires = expires
        self.renewable = renewable
        self.lease = lease
    }
}

/// What the TOTP engine holds about a key, apart from its secret.
public struct VaultKeyInfo: Sendable, Equatable {
    public var name: String
    public var accountName: String
    public var issuer: String
    public var algorithm: String
    public var digits: Int
    public var period: Int

    /// A name for the account, `<issuer>: <account name>`, or whichever is set, or the key's name.
    public var suggestedName: String {
        switch (issuer.isEmpty, accountName.isEmpty) {
        case (false, false):
            return "\(issuer): \(accountName)"
        case (false, true):
            return issuer
        case (true, false):
            return accountName
        case (true, true):
            return name
        }
    }

    /// The account showing this key's codes, which have the key's algorithm, digits and period.
    public func account(id: UUID = UUID(), name: String) throws -> Account {
        try Account(id: id, name: name, issuer: issuer.isEmpty ? nil : issuer, algorithm: algorithm,
                    digits: String(digits), period: String(period))
    }
}

/// A key Vault generated: its QR code as PNG data, when Vault made one, and its otpauth URL,
/// which holds the secret. Vault shows the secret only in the answer that creates the key.
public struct GeneratedKey: Sendable, Equatable {
    public var qrCode: Data?
    public var url: String
}

/// The calls of the Vault HTTP API that the app makes.
public struct VaultClient: Sendable {
    public let configuration: VaultConfiguration
    public var token: String?
    private let session: URLSession

    public init(configuration: VaultConfiguration, token: String? = nil, session: URLSession = .shared) {
        self.configuration = configuration
        self.token = token
        self.session = session
    }

    static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The request for `path` below `/v1/`, with the token and namespace headers.
    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [],
                     body: [String: any Sendable]? = nil, rawBody: Data? = nil,
                     contentType: String = "application/json") throws -> URLRequest {
        guard var components = URLComponents(string: configuration.address.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw VaultError.badAddress(configuration.address)
        }
        components.percentEncodedPath = "/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw VaultError.badAddress(configuration.address)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
        }
        if let namespace = configuration.namespace, !namespace.isEmpty {
            request.setValue(namespace, forHTTPHeaderField: "X-Vault-Namespace")
        }
        if let body = try rawBody ?? body.map({ try JSONSerialization.data(withJSONObject: $0) }) {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends the request and returns the body of a successful answer; other answers are errors
    /// carrying Vault's messages.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
              body: [String: any Sendable]? = nil, rawBody: Data? = nil,
              contentType: String = "application/json") async throws -> Data {
        try await exchange(method, path, query: query, body: body, rawBody: rawBody, contentType: contentType).data
    }

    /// Sends the request and returns the body and the status of the answer; an answer that is
    /// neither successful nor of a status in `allowing` is an error carrying Vault's messages.
    func exchange(_ method: String, _ path: String, query: [URLQueryItem] = [],
                  body: [String: any Sendable]? = nil, rawBody: Data? = nil,
                  contentType: String = "application/json",
                  allowing: Set<Int> = []) async throws -> (data: Data, status: Int) {
        let request = try makeRequest(method, path, query: query, body: body, rawBody: rawBody, contentType: contentType)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VaultError.badResponse("not an HTTP answer")
        }
        guard (200 ..< 300).contains(http.statusCode) || allowing.contains(http.statusCode) else {
            struct Errors: Decodable { let errors: [String]? }
            let messages = (try? JSONDecoder().decode(Errors.self, from: data))?.errors ?? []
            throw VaultError.http(status: http.statusCode, messages: messages)
        }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw VaultError.badResponse(String(describing: type))
        }
    }

    private struct AuthReply: Decodable {
        struct Auth: Decodable {
            let clientToken: String
            let leaseDuration: Int
            let renewable: Bool
        }

        let auth: Auth?
    }

    private func token(from data: Data, at now: Date) throws -> VaultToken {
        guard let auth = try decode(AuthReply.self, from: data).auth else {
            throw VaultError.badResponse("no auth block")
        }
        let lease = TimeInterval(auth.leaseDuration)
        return VaultToken(token: auth.clientToken, expires: lease > 0 ? now.addingTimeInterval(lease) : nil,
                          renewable: auth.renewable, lease: lease > 0 ? lease : nil)
    }

    private func authPath(_ suffix: String) -> String {
        "auth/\(VaultPath.escaped(configuration.authMount))/\(suffix)"
    }

    private func keysPath(_ suffix: String = "") -> String {
        "\(VaultPath.escaped(configuration.totpMount))/\(suffix)"
    }

    public func loginUserpass(username: String, password: String) async throws -> VaultToken {
        let escaped = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let data = try await send("POST", authPath("login/\(escaped)"), body: ["password": password])
        return try token(from: data, at: Date())
    }

    public func loginAppRole(roleID: String, secretID: String) async throws -> VaultToken {
        let data = try await send("POST", authPath("login"), body: ["role_id": roleID, "secret_id": secretID])
        return try token(from: data, at: Date())
    }

    /// The identity provider's authorisation URL for an OIDC login.
    public func oidcAuthURL(role: String?, redirectURI: String, clientNonce: String) async throws -> URL {
        struct Reply: Decodable {
            struct Payload: Decodable { let authUrl: String }
            let data: Payload
        }
        var body = ["redirect_uri": redirectURI, "client_nonce": clientNonce]
        if let role, !role.isEmpty {
            body["role"] = role
        }
        let data = try await send("POST", authPath("oidc/auth_url"), body: body)
        guard let url = URL(string: try decode(Reply.self, from: data).data.authUrl), !url.absoluteString.isEmpty else {
            throw VaultError.badResponse("no authorisation URL")
        }
        return url
    }

    /// Completes an OIDC login with the values the identity provider returned to the redirect URI.
    public func oidcCallback(state: String, nonce: String, code: String, clientNonce: String) async throws -> VaultToken {
        let query = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
                     URLQueryItem(name: "code", value: code), URLQueryItem(name: "client_nonce", value: clientNonce)]
        let data = try await send("GET", authPath("oidc/callback"), query: query)
        return try token(from: data, at: Date())
    }

    /// The status of Vault's health check, which also answers while Vault is sealed or in standby.
    func healthStatus() async throws -> Int {
        let (_, response) = try await session.data(for: makeRequest("GET", "sys/health"))
        guard let http = response as? HTTPURLResponse else {
            throw VaultError.badResponse("an HTTP answer")
        }
        return http.statusCode
    }

    /// The client's own token as Vault knows it, so its end is known.
    public func lookupSelf() async throws -> VaultToken {
        struct Reply: Decodable {
            struct Payload: Decodable {
                let ttl: Int
                let renewable: Bool?
            }
            let data: Payload
        }
        guard let token else {
            throw VaultError.notSignedIn
        }
        let now = Date()
        let payload = try decode(Reply.self, from: try await send("GET", "auth/token/lookup-self")).data
        let lease = TimeInterval(payload.ttl)
        return VaultToken(token: token, expires: lease > 0 ? now.addingTimeInterval(lease) : nil,
                          renewable: payload.renewable ?? false, lease: lease > 0 ? lease : nil)
    }

    public func renewSelf() async throws -> VaultToken {
        let now = Date()
        return try token(from: try await send("POST", "auth/token/renew-self", body: [:]), at: now)
    }

    /// The names of the TOTP engine's keys; none when the engine holds no key.
    public func listKeys() async throws -> [String] {
        struct Reply: Decodable {
            struct Payload: Decodable { let keys: [String] }
            let data: Payload
        }
        do {
            return try decode(Reply.self, from: try await send("LIST", keysPath("keys"))).data.keys
        } catch let error as VaultError {
            if case .http(404, _) = error {
                return []
            }
            throw error
        }
    }

    public func readKey(_ name: String) async throws -> VaultKeyInfo {
        struct Reply: Decodable {
            struct Payload: Decodable {
                let accountName: String?
                let issuer: String?
                let algorithm: String
                let digits: Int
                let period: Int
            }
            let data: Payload
        }
        let payload = try decode(Reply.self, from: try await send("GET", keysPath("keys/\(Self.escaped(name))"))).data
        return VaultKeyInfo(name: name, accountName: payload.accountName ?? "", issuer: payload.issuer ?? "",
                            algorithm: payload.algorithm, digits: payload.digits, period: payload.period)
    }

    /// Refuses a name that a key has already.
    private func requireNewKey(_ name: String) async throws {
        do {
            _ = try await readKey(name)
        } catch VaultError.http(let status, _) where status == 400 || status == 404 {
            return
        }
        throw VaultError.keyExists(name)
    }

    /// Has Vault generate a key.
    public func generateKey(_ name: String, issuer: String, accountName: String) async throws -> GeneratedKey {
        struct Reply: Decodable {
            struct Payload: Decodable {
                let barcode: String?
                let url: String
            }
            let data: Payload
        }
        try await requireNewKey(name)
        let data = try await send("POST", keysPath("keys/\(Self.escaped(name))"),
                                  body: ["generate": "true", "issuer": issuer, "account_name": accountName])
        let payload = try decode(Reply.self, from: data).data
        return GeneratedKey(qrCode: payload.barcode.flatMap { Data(base64Encoded: $0) }, url: payload.url)
    }

    /// Stores an existing key, given as a base32 secret or an otpauth URI, if Vault supports its
    /// parameters: 6 or 8 digits.
    public func importKey(_ name: String, input: String) async throws {
        let new = try Account.parse(name: name, input: input)
        guard [6, 8].contains(new.account.digits) else {
            throw VaultError.unsupportedKey("it has \(new.account.digits) digits; Vault supports 6 or 8.")
        }
        try await requireNewKey(name)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.lowercased().hasPrefix("otpauth://") ? ["url": text] : ["key": new.secret]
        _ = try await send("POST", keysPath("keys/\(Self.escaped(name))"), body: body)
    }

    /// The key's code for the present time.
    public func code(key: String) async throws -> String {
        struct Reply: Decodable {
            struct Payload: Decodable { let code: String }
            let data: Payload
        }
        return try decode(Reply.self, from: try await send("GET", keysPath("code/\(Self.escaped(key))"))).data.code
    }

    static func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    }
}

/// The paths a user types, a mount or a secret's name: slash-separated names, each of which is
/// escaped for the URL.
public enum VaultPath {
    /// Why the path cannot be used, or nil: an empty name, a name of dots, or a control character.
    public static func problem(_ path: String) -> String? {
        let names = VaultClient.trimmed(path).split(separator: "/", omittingEmptySubsequences: false)
        if names.isEmpty || names.contains(where: \.isEmpty) {
            return "it is empty or holds an empty name between slashes"
        }
        if names.contains(where: { $0 == "." || $0 == ".." }) {
            return "it holds a name of dots"
        }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "it holds a control character"
        }
        return nil
    }

    /// The path with each name percent-encoded, the slashes between them kept.
    public static func escaped(_ path: String) -> String {
        VaultClient.trimmed(path).split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }
}

/// A setting a user typed that cannot be used, and why.
public struct InvalidValue: Error, VaultProblemConvertible {
    public let what: String
    public let reason: String

    public init(what: String, reason: String) {
        self.what = what
        self.reason = reason
    }

    public var vaultProblem: VaultProblem {
        VaultProblem(kind: .credential, title: "\(what) is not valid", detail: "\(what) cannot be used: \(reason).",
                     suggestion: "Use names separated by single slashes, with no empty name or name of dots.")
    }
}

/// The version of a KV secrets engine.
public enum KVVersion: Int, Codable, CaseIterable, Sendable {
    case v1 = 1
    case v2 = 2
}

/// One field of a secret of a KV engine: the version of the engine, its mount, the secret's name
/// and the field. A secret is a single level of fields.
public struct SecretReference: Codable, Equatable, Sendable {
    public var version: KVVersion
    public var mount: String
    public var name: String
    public var field: String

    public init(version: KVVersion, mount: String, name: String, field: String) {
        self.version = version
        self.mount = mount
        self.name = name
        self.field = field
    }

    /// The reference with its mount and name trimmed of blanks and of slashes at their ends, or the
    /// error of the part that is empty.
    public func validated() throws -> SecretReference {
        func part(_ value: String, _ what: String) throws -> String {
            let trimmed = VaultClient.trimmed(value.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else {
                throw EmptyValue(what: what)
            }
            if let reason = VaultPath.problem(trimmed) {
                throw InvalidValue(what: what, reason: reason)
            }
            return trimmed
        }
        let field = field.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else {
            throw EmptyValue(what: "The field")
        }
        return SecretReference(version: version, mount: try part(mount, "The mount"), name: try part(name, "The secret name"),
                               field: field)
    }
}

extension VaultClient {
    /// The path of a secret's data: the KV v2 engine keeps it below `data/`.
    private func dataPath(_ reference: SecretReference) -> String {
        let mount = VaultPath.escaped(reference.mount)
        let name = VaultPath.escaped(reference.name)
        return reference.version == .v2 ? "\(mount)/data/\(name)" : "\(mount)/\(name)"
    }

    /// The fields of the secret as Vault holds them; nil when the secret does not exist. A KV v2
    /// secret whose latest version is deleted or destroyed is an error, not an absent secret.
    private func secretFields(_ reference: SecretReference) async throws -> [String: Any]? {
        let (data, status) = try await exchange("GET", dataPath(reference), allowing: [404])
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 404 {
            let metadata = (reply?["data"] as? [String: Any])?["metadata"] as? [String: Any]
            if reference.version == .v2, metadata?["destroyed"] as? Bool == true
                || !((metadata?["deletion_time"] as? String) ?? "").isEmpty {
                throw VaultError.secretDeleted(reference.name)
            }
            return nil
        }
        guard var fields = reply?["data"] as? [String: Any] else {
            throw VaultError.badResponse("secret")
        }
        if reference.version == .v2 {
            guard let inner = fields["data"] as? [String: Any] else {
                return nil
            }
            fields = inner
        }
        return fields
    }

    /// Whether the secret holds the field; a secret that does not exist does not.
    public func secretFieldExists(_ reference: SecretReference) async throws -> Bool {
        do {
            _ = try await readSecret(reference)
            return true
        } catch VaultError.noSecret(_) {
            return false
        } catch VaultError.missingField(_, _) {
            return false
        }
    }

    /// The text of the secret's field.
    public func readSecret(_ reference: SecretReference) async throws -> String {
        guard let fields = try await secretFields(reference) else {
            throw VaultError.noSecret(reference.name)
        }
        guard let value = fields[reference.field] else {
            throw VaultError.missingField(field: reference.field, secret: reference.name)
        }
        guard let text = value as? String else {
            throw VaultError.badResponse("the field \(reference.field) is not text")
        }
        return text
    }

    /// Sets the field of the secret, creating the secret when it does not exist, and keeps its
    /// other fields.
    public func writeSecret(_ reference: SecretReference, value: String) async throws {
        let path = dataPath(reference)
        switch reference.version {
        case .v2:
            do {
                _ = try await send("PATCH", path, body: ["data": [reference.field: value]],
                                   contentType: "application/merge-patch+json")
            } catch VaultError.http(let status, _) where status == 404 {
                _ = try await send("POST", path, body: ["options": ["cas": 0], "data": [reference.field: value]])
            }
        case .v1:
            // KV v1 has no compare-and-set, so the field is read back, and written again when another
            // writer's write replaced the secret and dropped it.
            for _ in 1 ... 3 {
                var fields = try await secretFields(reference) ?? [:]
                fields[reference.field] = value
                _ = try await send("POST", path, rawBody: try JSONSerialization.data(withJSONObject: fields))
                if (try await secretFields(reference))?[reference.field] as? String == value {
                    return
                }
            }
            throw VaultError.writeLost(reference.name)
        }
    }

    /// The names of the secrets directly below the mount; folders are left out.
    public func listSecrets(mount: String, version: KVVersion) async throws -> [String] {
        struct Reply: Decodable {
            struct Payload: Decodable { let keys: [String] }
            let data: Payload
        }
        let mount = VaultPath.escaped(mount)
        do {
            let data = try await send("LIST", version == .v2 ? "\(mount)/metadata" : mount)
            return try decode(Reply.self, from: data).data.keys.filter { !$0.hasSuffix("/") }
        } catch VaultError.http(let status, _) where status == 404 {
            return []
        }
    }
}

/// A setting or credential the authentication method needs and the form leaves empty.
struct EmptyValue: Error, VaultProblemConvertible {
    let what: String

    var vaultProblem: VaultProblem {
        VaultProblem(kind: .credential, title: "\(what) is empty", detail: "The authentication needs \(what.lowercased()).",
                     suggestion: "Provide it for the vault.")
    }
}

extension VaultClient {
    /// The token of a sign-in with the configured method and credential; nil for OIDC, which signs
    /// in through the identity provider's pages.
    public static func signIn(configuration: VaultConfiguration, credential: String?) async throws -> VaultToken? {
        func required(_ value: String?, _ what: String) throws -> String {
            guard let value, !value.isEmpty else {
                throw EmptyValue(what: what)
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
