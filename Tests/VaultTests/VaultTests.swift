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
        #expect(checks.map(\.step) == ["Address", "Server", "Token", "TOTP engine"])
        #expect(checks.map(\.outcome) == [.passed, .passed, .passed, .passed])
        #expect(checks[0].message == server.address)
        #expect(checks[2].message == "The token is valid and has no end.")
    }

    @Test func aConnectionTestSaysUntilWhenATokenEnds() async throws {
        let server = try server()
        let token = try await server.token(policy: "full")
        let checks = await VaultDiagnostics.run(configuration: configuration(server), credential: token)
        #expect(checks[2].step == "Token")
        #expect(checks[2].message.hasPrefix("The token is valid until "))
    }

    @Test func aConnectionTestLogsInWithAPassword() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .userpass),
                                                credential: VaultDevServer.password)
        #expect(checks.map(\.step) == ["Address", "Server", "Login", "TOTP engine"])
        #expect(checks[2].outcome == .passed)
        #expect(checks[2].message == "Vault issued a token to the user alice.")
    }

    @Test func aConnectionTestLogsInWithAnAppRole() async throws {
        let server = try server()
        var configuration = configuration(server, method: .approle)
        configuration.roleID = server.roleID
        let checks = await VaultDiagnostics.run(configuration: configuration, credential: server.secretID)
        #expect(checks.map(\.step) == ["Address", "Server", "Login", "TOTP engine"])
        #expect(checks[2].message == "Vault issued a token to the AppRole.")
    }

    @Test func aConnectionTestNamesARefusedLogin() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .userpass), credential: "wrong")
        #expect(checks.last?.step == "Login")
        #expect(checks.last?.outcome == .failed)
        #expect(checks.last?.message == "Vault refused the login.")
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
        #expect(checks.last?.step == "Token")
        #expect(checks.last?.outcome == .failed)
        #expect(checks.last?.message == "Vault did not accept the token.")
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

    @Test func aConnectionTestDoesNotTestOIDC() async throws {
        let server = try server()
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .oidc), credential: nil)
        #expect(checks.map(\.step) == ["Address", "Server", "Authentication", "TOTP engine"])
        #expect(checks.map(\.outcome) == [.passed, .passed, .skipped, .skipped])
        #expect(checks[2].message == "Not tested: an OIDC vault signs in interactively.")
        #expect(checks[3].message == "Not tested: there is no token.")
    }

    @Test func aConnectionTestChecksTheTokenOfAnOIDCSignIn() async throws {
        let server = try server()
        let token = VaultToken(token: server.rootToken, expires: nil, renewable: false)
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .oidc), credential: nil,
                                                signedInToken: token)
        #expect(checks.map(\.step) == ["Address", "Server", "Token", "TOTP engine"])
        #expect(checks[2].outcome == .passed)
        #expect(checks[3].outcome != .skipped)
    }

    @Test func aConnectionTestNamesTheStepOfARefusedOIDCToken() async throws {
        let server = try server()
        let token = VaultToken(token: "not-a-token", expires: nil, renewable: false)
        let checks = await VaultDiagnostics.run(configuration: configuration(server, method: .oidc), credential: nil,
                                                signedInToken: token)
        #expect(checks.last?.step == "Token")
        #expect(checks.last?.outcome == .failed)
        #expect(checks.last?.message == "Vault did not accept the token.")
        #expect(checks.last?.problem?.kind == .denied)
    }

    private func reference(_ version: KVVersion, name: String = "app", field: String = "password") -> SecretReference {
        SecretReference(version: version, mount: "kv\(version.rawValue)", name: name, field: field)
    }

    @Test(arguments: [KVVersion.v1, .v2])
    func readsAFieldOfASecret(version: KVVersion) async throws {
        let vault = client(try server(), token: try server().rootToken)
        #expect(try await vault.readSecret(reference(version)) == "p\(version.rawValue)")
        #expect(try await vault.readSecret(reference(version, field: "other")) == "keep\(version.rawValue)")
    }

    @Test(arguments: [KVVersion.v1, .v2])
    func aMissingSecretOrFieldIsNamed(version: KVVersion) async throws {
        let vault = client(try server(), token: try server().rootToken)
        await #expect(throws: VaultError.noSecret("nothing")) {
            try await vault.readSecret(reference(version, name: "nothing"))
        }
        await #expect(throws: VaultError.missingField(field: "nope", secret: "app")) {
            try await vault.readSecret(reference(version, field: "nope"))
        }
    }

    @Test(arguments: [KVVersion.v1, .v2])
    func writingAFieldKeepsTheOtherFields(version: KVVersion) async throws {
        let vault = client(try server(), token: try server().rootToken)
        try await vault.writeSecret(reference(version, name: "kept", field: "first"), value: "one")
        try await vault.writeSecret(reference(version, name: "kept", field: "second"), value: "two")
        try await vault.writeSecret(reference(version, name: "kept", field: "first"), value: "three")
        #expect(try await vault.readSecret(reference(version, name: "kept", field: "first")) == "three")
        #expect(try await vault.readSecret(reference(version, name: "kept", field: "second")) == "two")
    }

    @Test(arguments: [KVVersion.v1, .v2])
    func writingAFieldKeepsAFieldOfAnotherType(version: KVVersion) async throws {
        let server = try server()
        let vault = client(server, token: server.rootToken)
        if version == .v1 {
            try await server.admin("POST", "kv1/typed", ["count": 3])
        } else {
            try await server.admin("POST", "kv2/data/typed", ["data": ["count": 3]])
        }
        try await vault.writeSecret(reference(version, name: "typed", field: "password"), value: "pw")
        let reply = try await server.admin("GET", version == .v1 ? "kv1/typed" : "kv2/data/typed")
        let data = try #require(reply["data"] as? [String: Any])
        let fields = try #require(version == .v1 ? data : data["data"] as? [String: Any])
        #expect(fields["count"] as? Int == 3)
        #expect(fields["password"] as? String == "pw")
    }

    @Test(arguments: [KVVersion.v1, .v2])
    func listsTheSecretsOfAMountWithoutFolders(version: KVVersion) async throws {
        let vault = client(try server(), token: try server().rootToken)
        let names = try await vault.listSecrets(mount: "kv\(version.rawValue)/", version: version)
        #expect(names.contains("app"))
        #expect(!names.contains("dir/"))
        #expect(try await vault.listSecrets(mount: "nowhere", version: version).isEmpty)
    }

    @Test func aSecretReferenceIsTrimmedAndRefusedWhenAPartIsEmpty() throws {
        let trimmed = try SecretReference(version: .v2, mount: " /kv2/ ", name: "app/", field: " password ").validated()
        #expect(trimmed == SecretReference(version: .v2, mount: "kv2", name: "app", field: "password"))
        #expect(throws: (any Error).self) { try SecretReference(version: .v1, mount: "", name: "a", field: "f").validated() }
        #expect(throws: (any Error).self) { try SecretReference(version: .v1, mount: "m", name: " ", field: "f").validated() }
        #expect(throws: (any Error).self) { try SecretReference(version: .v1, mount: "m", name: "a", field: "").validated() }
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

    private func isDenied(_ error: Error) -> Bool {
        (error as? VaultError)?.isDenied == true
    }

    @Test func theSetupEnablesTheEngineAndWritesThePolicies() async throws {
        let server = try server()
        let options = VaultSetupOptions(mount: "setup-a/totp", creatorPolicy: "setup_a_creator", userPolicy: "setup_a_user")
        let checks = await VaultSetup.run(client: client(server, token: server.rootToken), options: options)
        #expect(checks.map(\.outcome) == [.passed, .passed, .passed])

        let creator = client(server, token: try await server.token(policy: "setup_a_creator"), mount: "setup-a/totp")
        try await creator.importKey("shared", input: VaultDevServer.secret)
        #expect(try await creator.readKey("shared").algorithm == "SHA1")
        await #expect { try await creator.code(key: "shared") } throws: { isDenied($0) }

        let user = client(server, token: try await server.token(policy: "setup_a_user"), mount: "setup-a/totp")
        #expect(try await user.code(key: "shared").count == 6)
        #expect(try await user.listKeys() == ["shared"])
        #expect(try await user.readKey("shared").issuer == "")
        await #expect { try await user.importKey("other", input: VaultDevServer.secret) } throws: { isDenied($0) }
    }

    @Test func aSecondSetupStopsAtTheEngineAndWritesNothing() async throws {
        let server = try server()
        let root = client(server, token: server.rootToken)
        let first = VaultSetupOptions(mount: "setup-b/totp", creatorPolicy: "setup_b_creator", userPolicy: "setup_b_user")
        #expect(await VaultSetup.run(client: root, options: first).map(\.outcome) == [.passed, .passed, .passed])

        let second = VaultSetupOptions(mount: "setup-b/totp", creatorPolicy: "setup_b2_creator", userPolicy: "setup_b2_user")
        let checks = await VaultSetup.run(client: root, options: second)
        #expect(checks.map(\.step) == ["Engine"])
        #expect(checks.map(\.outcome) == [.failed])
        await #expect(throws: DevServerError.self) {
            try await server.admin("GET", "sys/policies/acl/setup_b2_creator")
        }

        var policiesOnly = second
        policiesOnly.engineExists = true
        #expect(await VaultSetup.run(client: root, options: policiesOnly).map(\.outcome) == [.skipped, .passed, .passed])
    }

    @Test func anExistingPolicyStopsTheSetupUnlessItIsReplaced() async throws {
        let server = try server()
        let root = client(server, token: server.rootToken)
        var options = VaultSetupOptions(mount: "setup-c/totp", creatorPolicy: "setup_c_creator", userPolicy: "setup_c_user")
        #expect(await VaultSetup.run(client: root, options: options).map(\.outcome) == [.passed, .passed, .passed])

        options.engineExists = true
        let stopped = await VaultSetup.run(client: root, options: options)
        #expect(stopped.map(\.outcome) == [.skipped, .failed])
        #expect(stopped.last?.problem?.title == "The policy exists")

        options.overwritePolicies = true
        #expect(await VaultSetup.run(client: root, options: options).map(\.outcome) == [.skipped, .passed, .passed])
    }

    @Test func theSetupOfAKVEngineLetsTheCreatorWriteAndTheUserRead() async throws {
        let server = try server()
        let root = client(server, token: server.rootToken)
        let kv = KVSetupOptions(mount: "setup-e/kv", creatorPolicy: "setup_e_creator", userPolicy: "setup_e_user")
        let checks = await VaultSetup.run(client: root, options: VaultSetupOptions(totp: false, kv: kv))
        #expect(checks.map(\.step) == ["KV v2 engine", "KV v2 creator policy", "KV v2 user policy"])
        #expect(checks.map(\.outcome) == [.passed, .passed, .passed])

        let reference = SecretReference(version: .v2, mount: "setup-e/kv", name: "app", field: "password")
        let creator = client(server, token: try await server.token(policy: "setup_e_creator"))
        try await creator.writeSecret(reference, value: "one")
        try await creator.writeSecret(SecretReference(version: .v2, mount: "setup-e/kv", name: "app", field: "second"), value: "two")
        #expect(try await creator.readSecret(reference) == "one")
        #expect(try await creator.listSecrets(mount: "setup-e/kv", version: .v2) == ["app"])

        let user = client(server, token: try await server.token(policy: "setup_e_user"))
        #expect(try await user.readSecret(reference) == "one")
        #expect(try await user.listSecrets(mount: "setup-e/kv", version: .v2) == ["app"])
        await #expect { try await user.writeSecret(reference, value: "three") } throws: { isDenied($0) }
    }

    @Test func theSetupOfAKVv1EngineLetsTheCreatorWriteAndTheUserRead() async throws {
        let server = try server()
        let root = client(server, token: server.rootToken)
        let kv = KVSetupOptions(version: .v1, mount: "setup-g/kv", creatorPolicy: "setup_g_creator", userPolicy: "setup_g_user")
        let checks = await VaultSetup.run(client: root, options: VaultSetupOptions(totp: false, kv1: kv))
        #expect(checks.map(\.step) == ["KV v1 engine", "KV v1 creator policy", "KV v1 user policy"])
        #expect(checks.map(\.outcome) == [.passed, .passed, .passed])

        let reference = SecretReference(version: .v1, mount: "setup-g/kv", name: "app", field: "password")
        let creator = client(server, token: try await server.token(policy: "setup_g_creator"))
        try await creator.writeSecret(reference, value: "one")
        try await creator.writeSecret(SecretReference(version: .v1, mount: "setup-g/kv", name: "app", field: "second"), value: "two")
        #expect(try await creator.readSecret(reference) == "one")
        #expect(try await creator.listSecrets(mount: "setup-g/kv", version: .v1) == ["app"])

        let user = client(server, token: try await server.token(policy: "setup_g_user"))
        #expect(try await user.readSecret(reference) == "one")
        #expect(try await user.listSecrets(mount: "setup-g/kv", version: .v1) == ["app"])
        await #expect { try await user.writeSecret(reference, value: "three") } throws: { isDenied($0) }
    }

    @Test func theSetupOfEveryEngineRunsTheTOTPStepsFirstThenKVv2ThenKVv1() async throws {
        let server = try server()
        let options = VaultSetupOptions(mount: "setup-h/totp", creatorPolicy: "setup_h_creator", userPolicy: "setup_h_user",
                                        kv: KVSetupOptions(mount: "setup-h/kv2", creatorPolicy: "setup_h_kv2_creator",
                                                           userPolicy: "setup_h_kv2_user"),
                                        kv1: KVSetupOptions(version: .v1, mount: "setup-h/kv1", creatorPolicy: "setup_h_kv1_creator",
                                                            userPolicy: "setup_h_kv1_user"))
        let checks = await VaultSetup.run(client: client(server, token: server.rootToken), options: options)
        #expect(checks.map(\.step).filter { $0.lowercased().hasSuffix("engine") } == ["Engine", "KV v2 engine", "KV v1 engine"])
        #expect(checks.count == 9)
        #expect(checks.allSatisfy { $0.outcome == .passed })
    }

    @Test func theSetupOfBothEnginesRunsTheTOTPStepsFirst() async throws {
        let server = try server()
        let options = VaultSetupOptions(mount: "setup-f/totp", creatorPolicy: "setup_f_creator", userPolicy: "setup_f_user",
                                        kv: KVSetupOptions(mount: "setup-f/kv", creatorPolicy: "setup_f_kv_creator",
                                                           userPolicy: "setup_f_kv_user"))
        let checks = await VaultSetup.run(client: client(server, token: server.rootToken), options: options)
        #expect(checks.map(\.step) == ["Engine", "Creator policy", "User policy", "KV v2 engine", "KV v2 creator policy", "KV v2 user policy"])
        #expect(checks.allSatisfy { $0.outcome == .passed })
    }

    @Test func theSetupStopsAtTheFirstCallThatIsDenied() async throws {
        let server = try server()
        let denied = client(server, token: try await server.token(policy: "nolist"))
        let checks = await VaultSetup.run(client: denied, options: VaultSetupOptions(mount: "setup-d/totp"))
        #expect(checks.map(\.outcome) == [.failed])
        #expect(checks.first?.problem?.kind == .denied)
    }

    @Test func theSetupOfBadOptionsMakesNoCall() async throws {
        let server = try server()
        let checks = await VaultSetup.run(client: client(server, token: server.rootToken),
                                          options: VaultSetupOptions(mount: "has space/totp"))
        #expect(checks.map(\.step) == ["Settings"])
        #expect(checks.map(\.outcome) == [.failed])
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

@Suite struct OIDCSignInPolicyTests {
    private let policy = OIDCSignInPolicy(redirect: URL(string: "http://localhost:8250/oidc/callback")!)

    private func decide(_ address: String?) -> OIDCNavigation {
        policy.decide(address.flatMap { URL(string: $0) })
    }

    @Test func theRedirectEndsTheSignInWithItsCallback() {
        #expect(decide("http://localhost:8250/oidc/callback?state=abc&code=x%20y")
            == .callback(OIDCCallback(state: "abc", code: "x y", error: nil)))
    }

    @Test func aProviderErrorIsCarriedByTheCallback() {
        let navigation = decide("http://localhost:8250/oidc/callback?error=access_denied&error_description=No%20way&state=s")
        #expect(navigation == .callback(OIDCCallback(state: "s", code: nil, error: "No way")))
        #expect(decide("http://localhost:8250/oidc/callback?error=access_denied")
            == .callback(OIDCCallback(state: nil, code: nil, error: "access_denied")))
    }

    @Test func theHostOfTheRedirectIsComparedWithoutCase() {
        #expect(decide("http://LOCALHOST:8250/oidc/callback?code=c") == .callback(OIDCCallback(state: nil, code: "c", error: nil)))
    }

    @Test(arguments: [
        "http://localhost:9999/oidc/callback?code=c",
        "http://localhost:8250/other?code=c",
        "http://127.0.0.1:8250/oidc/callback?code=c",
        "http://evil.example.com:8250/oidc/callback?code=c",
    ])
    func aLookalikeOfTheRedirectIsNotTheCallback(address: String) {
        guard case .block = decide(address) else {
            Issue.record("\(address) was not blocked")
            return
        }
    }

    @Test(arguments: ["https://login.example.com/authorize?x=1", "https://login.example.com:8443/", "about:blank"])
    func aSecurePageLoads(address: String) {
        #expect(decide(address) == .allow)
    }

    @Test(arguments: [
        "http://login.example.com/authorize", "data:text/html,hello", "file:///etc/hosts",
        "javascript:alert(1)", "macauthenticator://callback", "about:srcdoc", nil,
    ] as [String?])
    func anyOtherPageIsBlocked(address: String?) {
        guard case .block = decide(address) else {
            Issue.record("\(address ?? "no address") was not blocked")
            return
        }
    }

    @Test func aBlockedPlainHTTPPageIsNamed() {
        #expect(decide("http://login.example.com/authorize") == .block("The page login.example.com is not served over HTTPS."))
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

@Suite struct VaultSetupPolicyTests {
    @Test func theCreatorPolicyListsCreatesAndReadsKeys() {
        let policy = VaultSetup.creatorPolicy(mount: "totp")
        #expect(policy.contains("path \"totp/keys\" {\n  capabilities = [\"list\"]"))
        #expect(policy.contains("path \"totp/keys/*\" {\n  capabilities = [\"create\", \"update\", \"read\"]"))
        #expect(!policy.contains("code"))
        #expect(!policy.contains("delete"))
    }

    @Test func theUserPolicyReadsKeysAndCodes() {
        let policy = VaultSetup.userPolicy(mount: "totp")
        #expect(policy.contains("path \"totp/keys/*\" {\n  capabilities = [\"read\"]"))
        #expect(policy.contains("path \"totp/code/*\" {\n  capabilities = [\"read\"]"))
        #expect(!policy.contains("create"))
    }

    @Test func theKVCreatorPolicyListsAndWritesAndReadsSecrets() {
        let policy = VaultSetup.kvCreatorPolicy(mount: "secret")
        #expect(policy.contains("path \"secret/metadata\" {\n  capabilities = [\"list\"]"))
        #expect(policy.contains("path \"secret/data/*\" {\n  capabilities = [\"create\", \"update\", \"patch\", \"read\"]"))
        #expect(!policy.contains("delete"))
    }

    @Test func theKVUserPolicyListsAndReadsSecrets() {
        let policy = VaultSetup.kvUserPolicy(mount: "/team/secret/")
        #expect(policy.contains("path \"team/secret/metadata\" {\n  capabilities = [\"list\"]"))
        #expect(policy.contains("path \"team/secret/data/*\" {\n  capabilities = [\"read\"]"))
        #expect(!policy.contains("create"))
    }

    @Test func theKVv1PoliciesNameTheMountsPathsWithoutDataOrMetadata() {
        let creator = VaultSetup.kvCreatorPolicy(mount: "kv", version: .v1)
        #expect(creator.contains("path \"kv/*\" {\n  capabilities = [\"list\", \"create\", \"update\", \"read\"]"))
        #expect(!creator.contains("data") && !creator.contains("metadata") && !creator.contains("patch"))
        let user = VaultSetup.kvUserPolicy(mount: "/kv/", version: .v1)
        #expect(user.contains("path \"kv/*\" {\n  capabilities = [\"list\", \"read\"]"))
        #expect(!user.contains("create"))
    }

    @Test func aMountIsTrimmedAndMayBeNested() {
        let policy = VaultSetup.userPolicy(mount: "/team/totp/")
        #expect(policy.contains("path \"team/totp/keys\""))
        #expect(policy.contains("path \"team/totp/code/*\""))
    }

    @Test(arguments: [
        VaultSetupOptions(mount: ""),
        VaultSetupOptions(mount: "a b"),
        VaultSetupOptions(creatorPolicy: ""),
        VaultSetupOptions(userPolicy: "has space"),
        VaultSetupOptions(creatorPolicy: "same", userPolicy: "same"),
        VaultSetupOptions(totp: false),
        VaultSetupOptions(kv: KVSetupOptions(mount: "totp")),
        VaultSetupOptions(kv: KVSetupOptions(mount: "")),
        VaultSetupOptions(kv: KVSetupOptions(creatorPolicy: "totp_creator")),
        VaultSetupOptions(kv: KVSetupOptions(userPolicy: "has space")),
        VaultSetupOptions(kv: KVSetupOptions(), kv1: KVSetupOptions(version: .v1, mount: "secret")),
        VaultSetupOptions(kv: KVSetupOptions(), kv1: KVSetupOptions(version: .v1, creatorPolicy: "kv_creator")),
        VaultSetupOptions(totp: false, kv1: KVSetupOptions(version: .v1, mount: "")),
    ])
    func optionsThatCannotBeUsedAreRefused(options: VaultSetupOptions) {
        #expect(VaultSetup.problem(of: options) != nil)
    }

    @Test func theDefaultsAreUsable() {
        #expect(VaultSetup.problem(of: VaultSetupOptions()) == nil)
        #expect(VaultSetup.problem(of: VaultSetupOptions(kv: KVSetupOptions())) == nil)
        #expect(VaultSetup.problem(of: VaultSetupOptions(totp: false, kv: KVSetupOptions())) == nil)
        #expect(VaultSetup.problem(of: VaultSetupOptions(totp: false, kv1: KVSetupOptions(version: .v1))) == nil)
        #expect(VaultSetup.problem(of: VaultSetupOptions(kv: KVSetupOptions(), kv1: KVSetupOptions(version: .v1))) == nil)
    }
}
