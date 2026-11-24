import Foundation
import Testing

/// A failure to run or prepare the Vault dev server the tests need.
struct DevServerError: Error, CustomStringConvertible {
    let description: String
}

/// A running `vault server -dev` with in-memory storage, prepared with the engines, policies and
/// identities the tests use.
struct VaultDevServer: Sendable {
    static let defaultPort = 18200
    /// The base32 secret of the keys the tests create.
    static let secret = "JBSWY3DPEHPK3PXP"
    static let password = "correct horse"

    @TaskLocal static var current: VaultDevServer?

    let port: Int
    let rootToken: String
    var address: String { "http://127.0.0.1:\(port)" }
    var roleID = ""
    var secretID = ""

    /// Calls Vault's API with the root token, without the client under test.
    @discardableResult
    func admin(_ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(address)/v1/\(path)")!)
        request.httpMethod = method
        request.setValue(token ?? rootToken, forHTTPHeaderField: "X-Vault-Token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw DevServerError(description: "\(method) \(path) answered \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A new token with the policy; `renewable` tokens last an hour.
    func token(policy: String) async throws -> String {
        let reply = try await admin("POST", "auth/token/create", ["policies": [policy], "ttl": "1h", "renewable": true])
        return try #require((reply["auth"] as? [String: Any])?["client_token"] as? String)
    }

    private static func policy(listing: Bool) -> String {
        ["totp", "team/totp"].map { mount in
            """
            \(listing ? "path \"\(mount)/keys\" { capabilities = [\"list\"] }" : "")
            path "\(mount)/keys/*" { capabilities = ["read"] }
            path "\(mount)/code/*" { capabilities = ["read"] }
            """
        }.joined(separator: "\n")
    }

    /// Starts the server, prepares it, runs `body` and stops the server.
    static func run(_ body: @Sendable (VaultDevServer) async throws -> Void) async throws {
        let environment = ProcessInfo.processInfo.environment
        let port = environment["VAULT_TEST_PORT"].flatMap { Int($0) } ?? defaultPort
        var server = VaultDevServer(port: port, rootToken: "root-" + UUID().uuidString.lowercased())

        let process = Process()
        if let binary = environment["VAULT_BINARY"] {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = []
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["vault"]
        }
        process.arguments? += ["server", "-dev", "-dev-root-token-id=\(server.rootToken)",
                               "-dev-listen-address=127.0.0.1:\(port)", "-dev-no-store-token"]
        process.environment = environment.filter { !$0.key.hasPrefix("VAULT_ADDR") && $0.key != "VAULT_TOKEN" }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DevServerError(description: "The vault binary could not be run: \(error). Install Vault or set VAULT_BINARY.")
        }
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(10)
        var healthy = false
        while !healthy {
            guard process.isRunning else {
                throw DevServerError(description: "The vault dev server exited with status \(process.terminationStatus); is `vault` installed and port \(port) free?")
            }
            guard Date() < deadline else {
                throw DevServerError(description: "The vault dev server was not healthy within 10 seconds.")
            }
            let health = URLRequest(url: URL(string: "\(server.address)/v1/sys/health")!)
            if let (_, response) = try? await URLSession.shared.data(for: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                healthy = true
            } else {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await server.prepare()
        try await body(server)
    }

    /// Enables the engines and methods and creates the keys, policies and identities.
    private mutating func prepare() async throws {
        try await admin("POST", "sys/mounts/totp", ["type": "totp"])
        try await admin("POST", "sys/mounts/team/totp", ["type": "totp"])
        try await admin("POST", "sys/mounts/scratch/totp", ["type": "totp"])
        try await admin("POST", "totp/keys/default", ["key": Self.secret, "issuer": "Acme", "account_name": "alice@example.com"])
        try await admin("POST", "totp/keys/strong", ["key": Self.secret, "issuer": "Acme", "account_name": "bob@example.com",
                                                    "algorithm": "SHA256", "digits": 8, "period": 60])
        try await admin("POST", "team/totp/keys/shared", ["key": Self.secret, "account_name": "team"])

        try await admin("PUT", "sys/policies/acl/full", ["policy": Self.policy(listing: true)])
        try await admin("PUT", "sys/policies/acl/nolist", ["policy": Self.policy(listing: false)])

        try await admin("POST", "sys/auth/userpass", ["type": "userpass"])
        try await admin("POST", "auth/userpass/users/alice", ["password": Self.password, "token_policies": ["full"]])

        try await admin("POST", "sys/auth/approle", ["type": "approle"])
        try await admin("POST", "auth/approle/role/app", ["token_policies": ["full"], "token_ttl": "1h"])
        let roleReply = try await admin("GET", "auth/approle/role/app/role-id")
        roleID = try #require((roleReply["data"] as? [String: Any])?["role_id"] as? String)
        let secretReply = try await admin("POST", "auth/approle/role/app/secret-id")
        secretID = try #require((secretReply["data"] as? [String: Any])?["secret_id"] as? String)
    }
}

/// Runs the whole suite against one dev server.
struct VaultDevServerTrait: SuiteTrait, TestScoping {
    let isRecursive = false

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await VaultDevServer.run { server in
            try await VaultDevServer.$current.withValue(server) {
                try await function()
            }
        }
    }
}

extension Trait where Self == VaultDevServerTrait {
    static var vaultDevServer: Self {
        Self()
    }
}
