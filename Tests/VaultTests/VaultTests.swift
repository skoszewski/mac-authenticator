import Foundation
import Testing
import TOTP
@testable import Vault

@Suite(.vaultDevServer)
struct VaultAgainstDevServerTests {
    private func server() throws -> VaultDevServer {
        try #require(VaultDevServer.current)
    }

    private func client(_ server: VaultDevServer, token: String? = nil, mount: String = "totp",
                        method: AuthMethod = .token) -> VaultClient {
        VaultClient(configuration: VaultConfiguration(address: server.address, totpMount: mount, authMethod: method),
                    token: token)
    }

    @Test func tokenLookupReportsTheEndOfTheToken() async throws {
        let server = try server()
        let token = try await server.token(policy: "full")
        let found = try await client(server, token: token).lookupSelf()
        #expect(found.token == token)
        #expect(found.renewable)
        let expires = try #require(found.expires)
        #expect(expires > Date().addingTimeInterval(3000))
    }

    @Test func rootTokenHasNoEnd() async throws {
        let server = try server()
        let found = try await client(server, token: server.rootToken).lookupSelf()
        #expect(found.expires == nil)
    }

    @Test func userpassLogin() async throws {
        let server = try server()
        let vault = client(server, method: .userpass)
        let token = try await vault.loginUserpass(username: "alice", password: VaultDevServer.password)
        #expect(!token.token.isEmpty)
        #expect(try await client(server, token: token.token).listKeys().contains("default"))
        await #expect(throws: VaultError.self) {
            try await vault.loginUserpass(username: "alice", password: "wrong")
        }
    }

    @Test func approleLogin() async throws {
        let server = try server()
        let vault = client(server, method: .approle)
        let token = try await vault.loginAppRole(roleID: server.roleID, secretID: server.secretID)
        #expect(try await client(server, token: token.token).listKeys().contains("strong"))
        await #expect(throws: VaultError.self) {
            try await vault.loginAppRole(roleID: server.roleID, secretID: "wrong")
        }
    }

    @Test func renewingAToken() async throws {
        let server = try server()
        let renewed = try await client(server, token: try await server.token(policy: "full")).renewSelf()
        #expect(renewed.renewable)
        #expect(renewed.expires != nil)
    }

    @Test func listingKeysOfTwoMounts() async throws {
        let server = try server()
        let token = try await server.token(policy: "full")
        #expect(try await client(server, token: token).listKeys().sorted() == ["default", "strong"])
        #expect(try await client(server, token: token, mount: "/team/totp/").listKeys() == ["shared"])
    }

    @Test func listingIsDeniedWithoutThePolicy() async throws {
        let server = try server()
        let vault = client(server, token: try await server.token(policy: "nolist"))
        await #expect {
            try await vault.listKeys()
        } throws: { error in
            (error as? VaultError)?.isDenied == true
        }
        #expect(try await vault.code(key: "default").count == 6)
    }

    @Test func readingAKeyGivesItsParameters() async throws {
        let server = try server()
        let vault = client(server, token: try await server.token(policy: "full"))
        let strong = try await vault.readKey("strong")
        #expect(strong == VaultKeyInfo(name: "strong", accountName: "bob@example.com", issuer: "Acme",
                                       algorithm: "SHA256", digits: 8, period: 60))
        #expect(strong.suggestedName == "Acme: bob@example.com")
        let account = try strong.account(name: "Bob")
        #expect(account.algorithm == .sha256 && account.digits == 8 && account.period == 60)
        let shared = client(server, token: try await server.token(policy: "full"), mount: "team/totp")
        #expect(try await shared.readKey("shared").suggestedName == "team")
    }

    @Test(arguments: ["default", "strong"])
    func codesAgreeWithTheTOTPLibrary(key: String) async throws {
        let server = try server()
        let vault = client(server, token: try await server.token(policy: "full"))
        let account = try await vault.readKey(key).account(name: key)
        // Stay clear of a period boundary between Vault's clock reading and ours.
        while account.secondsLeft(at: Date()) < 3 {
            try await Task.sleep(for: .milliseconds(250))
        }
        let code = try await vault.code(key: key)
        #expect(code == account.code(secret: VaultDevServer.secret, at: Date()))
    }

    @Test func aGeneratedKeyComesWithItsQRCodeAndURL() async throws {
        let server = try server()
        let vault = client(server, token: server.rootToken, mount: "scratch/totp")
        let generated = try await vault.generateKey("generated", issuer: "Acme", accountName: "carol@example.com")
        let png = try #require(generated.qrCode)
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let parsed = try Account.parse(name: "", input: generated.url)
        #expect(parsed.account.name == "Acme: carol@example.com")
        let info = try await vault.readKey("generated")
        #expect(info.issuer == "Acme" && info.accountName == "carol@example.com")
        let account = try info.account(name: "generated")
        while account.secondsLeft(at: Date()) < 3 {
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(try await vault.code(key: "generated") == account.code(secret: parsed.secret, at: Date()))
    }

    @Test func aKeyIsNotReplacedByGenerating() async throws {
        let server = try server()
        let vault = client(server, token: server.rootToken)
        await #expect(throws: VaultError.keyExists("default")) {
            try await vault.generateKey("default", issuer: "Acme", accountName: "mallory")
        }
        await #expect(throws: VaultError.keyExists("default")) {
            try await vault.importKey("default", input: VaultDevServer.secret)
        }
    }

    @Test func generatingNeedsTheWritePolicy() async throws {
        let server = try server()
        let vault = client(server, token: try await server.token(policy: "full"), mount: "scratch/totp")
        await #expect {
            try await vault.generateKey("denied", issuer: "Acme", accountName: "dave")
        } throws: { error in
            (error as? VaultError)?.isDenied == true
        }
    }

    @Test(arguments: [
        VaultDevServer.secret,
        "otpauth://totp/Acme:erin@example.com?secret=\(VaultDevServer.secret)&digits=8&algorithm=SHA256&period=60",
    ])
    func anImportedKeyGivesTheCodesOfItsSecret(input: String) async throws {
        let server = try server()
        let vault = client(server, token: server.rootToken, mount: "scratch/totp")
        let name = "imported-" + UUID().uuidString.lowercased()
        try await vault.importKey(name, input: input)
        let info = try await vault.readKey(name)
        let account = try info.account(name: name)
        if input.hasPrefix("otpauth") {
            #expect(info.issuer == "Acme" && account.algorithm == .sha256 && account.digits == 8 && account.period == 60)
        }
        while account.secondsLeft(at: Date()) < 3 {
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(try await vault.code(key: name) == account.code(secret: VaultDevServer.secret, at: Date()))
    }

    @Test(arguments: ["otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=7", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=10"])
    func anImportedKeyOfUnsupportedDigitsIsRefused(input: String) async throws {
        let server = try server()
        let vault = client(server, token: server.rootToken, mount: "scratch/totp")
        await #expect(throws: VaultError.self) {
            try await vault.importKey("unsupported", input: input)
        }
        await #expect(throws: VaultError.http(status: 400, messages: ["unknown key: unsupported"])) {
            try await vault.code(key: "unsupported")
        }
    }

    private func configuration(_ server: VaultDevServer, address: String? = nil,
                               method: AuthMethod = .token) -> VaultConfiguration {
        VaultConfiguration(address: address ?? server.address, authMethod: method, username: "alice")
    }

    @Test func aConnectionTestPassesAgainstTheServer() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server), credential: server.rootToken)
        #expect(checks.map(\.step) == ["Address", "Server", "Sign-in", "TOTP engine"])
        #expect(checks.map(\.outcome) == [.passed, .passed, .passed, .passed])
    }

    @Test func aConnectionTestNamesTheStepOfAnUnreachableServer() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, address: "http://127.0.0.1:1"),
                                                credential: server.rootToken)
        #expect(checks.map(\.step) == ["Address", "Server"])
        #expect(checks.last?.outcome == .failed)
        #expect(checks.last?.problem?.kind == .network)
    }

    @Test func aConnectionTestNamesTheStepOfARefusedToken() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server), credential: "not-a-token")
        #expect(checks.last?.step == "Sign-in")
        #expect(checks.last?.outcome == .failed)
        #expect(checks.last?.problem?.kind == .denied)
    }

    @Test func aConnectionTestWarnsWhenTheKeysCannotBeListed() async throws {
        let server = try server()
        let token = try await server.token(policy: "nolist")
        let checks = await VaultDiagnostics.run(configuration: configuration(server), credential: token)
        #expect(checks.last?.step == "TOTP engine")
        #expect(checks.last?.outcome == .warning)
        #expect(checks.last?.problem?.kind == .denied)
    }

    @Test func aConnectionTestOfABadAddressStopsAtTheAddress() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, address: "vault"), credential: nil)
        #expect(checks.map(\.step) == ["Address"])
        #expect(checks.first?.problem?.kind == .address)
    }

    @Test func aConnectionTestSkipsTheSignInOfOIDC() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .oidc), credential: nil)
        #expect(checks.map(\.outcome) == [.passed, .passed, .skipped, .skipped])
    }

    @Test(arguments: ["localhost", "127.0.0.1", "127.1.2.3", "::1"])
    func aHostOfThisMacResolvesToLoopback(host: String) async {
        #expect(await VaultDiagnostics.resolvesToLoopback(host))
    }

    @Test(arguments: ["192.168.1.10", "10.0.0.1", "8.8.8.8", "2001:db8::1", "vault.invalid"])
    func aHostOfAnotherMachineDoesNotResolveToLoopback(host: String) async {
        #expect(!(await VaultDiagnostics.resolvesToLoopback(host)))
    }

    @Test func aConnectionTestWarnsOfPlainHTTPToAnotherHost() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, address: "http://vault.invalid:1"),
                                                credential: server.rootToken)
        #expect(checks.first?.step == "Address")
        #expect(checks.first?.outcome == .warning)
    }

    @Test func aRevokedTokenIsDenied() async throws {
        let server = try server()
        let token = try await server.token(policy: "full")
        let vault = client(server, token: token)
        _ = try await vault.listKeys()
        try await server.admin("POST", "auth/token/revoke", ["token": token])
        await #expect {
            try await vault.listKeys()
        } throws: { error in
            (error as? VaultError)?.isDenied == true
        }
    }

    @Test func aMissingKeyIsReportedWithVaultsMessage() async throws {
        let server = try server()
        let vault = client(server, token: try await server.token(policy: "full"))
        await #expect(throws: VaultError.http(status: 400, messages: ["unknown key: nothing"])) {
            try await vault.code(key: "nothing")
        }
    }
}

@Suite struct VaultRequestTests {
    @Test func requestsCarryTheTokenAndNamespace() throws {
        let configuration = VaultConfiguration(address: "https://vault.example.com:8200/", namespace: "team-a",
                                               totpMount: "/otp/")
        let request = try VaultClient(configuration: configuration, token: "t").makeRequest("LIST", "otp/keys")
        #expect(request.url?.absoluteString == "https://vault.example.com:8200/v1/otp/keys")
        #expect(request.httpMethod == "LIST")
        #expect(request.value(forHTTPHeaderField: "X-Vault-Token") == "t")
        #expect(request.value(forHTTPHeaderField: "X-Vault-Namespace") == "team-a")
    }

    @Test(arguments: ["", "vault", "ftp://vault.example.com", "http://"])
    func badAddressesAreRefused(address: String) {
        #expect(throws: VaultError.badAddress(address)) {
            try VaultClient(configuration: VaultConfiguration(address: address)).makeRequest("GET", "sys/health")
        }
    }

    @Test func configurationDefaults() {
        let configuration = VaultConfiguration(address: "http://127.0.0.1:8200", authMethod: .approle)
        #expect(configuration.authMount == "approle")
        #expect(configuration.totpMount == "totp")
        #expect(configuration.oidcRedirectURI == "http://localhost:8250/oidc/callback")
    }
}

@Suite struct OIDCCallbackTests {
    @Test func parsesTheRequestLine() {
        let request = "GET /oidc/callback?state=abc&code=x%20y HTTP/1.1\r\nHost: localhost:8250\r\n\r\n"
        #expect(OIDCCallbackListener.parse(request: request) == OIDCCallback(state: "abc", code: "x y", error: nil))
    }

    @Test func parsesAProviderError() {
        let request = "GET /oidc/callback?error=access_denied&error_description=No%20way&state=s HTTP/1.1\r\n\r\n"
        #expect(OIDCCallbackListener.parse(request: request)?.error == "No way")
    }

    @Test(arguments: ["GET /favicon.ico HTTP/1.1\r\n\r\n", "POST /oidc/callback HTTP/1.1\r\n\r\n", ""])
    func ignoresOtherRequests(request: String) {
        #expect(OIDCCallbackListener.parse(request: request) == nil)
    }

    @Test func receivesTheBrowsersRedirect() async throws {
        let listener = try OIDCCallbackListener(port: 18250)
        try await listener.start()
        defer { listener.cancel() }

        let url = try #require(URL(string: "http://localhost:18250/oidc/callback?state=s1&code=c1"))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("You can close this tab"))
        #expect(try await listener.callback(timeout: .seconds(5)) == OIDCCallback(state: "s1", code: "c1", error: nil))
    }

    @Test func timesOutWithoutARedirect() async throws {
        let listener = try OIDCCallbackListener(port: 18251)
        try await listener.start()
        defer { listener.cancel() }
        await #expect(throws: VaultError.self) {
            try await listener.callback(timeout: .milliseconds(300))
        }
    }
}

@Suite struct VaultProblemTests {
    private func problem(_ code: URLError.Code) -> VaultProblem {
        let url = URL(string: "https://vault.example.com:8200")!
        return VaultProblem(URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url]))
    }

    @Test(arguments: [
        (URLError.Code.cannotFindHost, VaultProblem.Kind.network),
        (.cannotConnectToHost, .network),
        (.timedOut, .network),
        (.notConnectedToInternet, .network),
        (.networkConnectionLost, .network),
        (.secureConnectionFailed, .tls),
        (.serverCertificateUntrusted, .tls),
        (.serverCertificateHasUnknownRoot, .tls),
        (.serverCertificateHasBadDate, .tls),
        (.appTransportSecurityRequiresSecureConnection, .tls),
        (.badServerResponse, .response),
        (.badURL, .address),
    ])
    func aURLErrorIsSaidInWords(code: URLError.Code, kind: VaultProblem.Kind) {
        let found = problem(code)
        #expect(found.kind == kind)
        #expect(!found.title.isEmpty && !found.detail.isEmpty && !found.suggestion.isEmpty)
        #expect(found.title != "The connection failed")
    }

    @Test func aNameThatDoesNotResolveNamesTheHost() {
        #expect(problem(.cannotFindHost).detail.contains("vault.example.com"))
    }

    @Test(arguments: [
        (400, VaultProblem.Kind.server), (403, .denied), (404, .server), (429, .server), (503, .server), (500, .server),
    ])
    func anHTTPStatusIsSaidInWords(status: Int, kind: VaultProblem.Kind) {
        let found = VaultProblem(VaultError.http(status: status, messages: ["permission denied"]))
        #expect(found.kind == kind)
        #expect(found.detail.contains("permission denied"))
        #expect(!found.suggestion.isEmpty)
    }

    @Test func aProblemOfAnotherErrorKeepsItsText() {
        struct Odd: LocalizedError { var errorDescription: String? { "odd failure" } }
        let found = VaultProblem(Odd())
        #expect(found.kind == .other)
        #expect(found.detail == "odd failure")
    }
}
