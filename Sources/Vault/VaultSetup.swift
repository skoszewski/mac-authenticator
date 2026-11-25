import Foundation

/// What the setup of a KV engine for secrets is asked to do.
public struct KVSetupOptions: Equatable, Sendable {
    public var version: KVVersion
    public var mount: String
    public var description: String
    public var creatorPolicy: String
    public var userPolicy: String
    /// The engine is enabled already, so only the policies are written.
    public var engineExists: Bool

    public init(version: KVVersion = .v2, mount: String? = nil, description: String? = nil,
                creatorPolicy: String? = nil, userPolicy: String? = nil, engineExists: Bool = false) {
        self.version = version
        let name = version == .v2 ? "kv" : "kv1"
        self.mount = mount ?? (version == .v2 ? "secret" : "kv")
        self.description = description ?? "KV v\(version.rawValue) secrets engine"
        self.creatorPolicy = creatorPolicy ?? "\(name)_creator"
        self.userPolicy = userPolicy ?? "\(name)_user"
        self.engineExists = engineExists
    }
}

/// What the setup of a vault is asked to do: the TOTP engine and its policies, a KV v2 engine and a
/// KV v1 engine, each with its policies, any of them or all.
public struct VaultSetupOptions: Equatable, Sendable {
    public var mount: String
    public var description: String
    public var creatorPolicy: String
    public var userPolicy: String
    /// Replace policies of these names that exist; otherwise the setup stops at one.
    public var overwritePolicies: Bool
    /// The engine is enabled already, so only the policies are written.
    public var engineExists: Bool
    /// Set up the TOTP engine.
    public var totp: Bool
    /// The KV v2 engine to set up, or nil for none.
    public var kv: KVSetupOptions?
    /// The KV v1 engine to set up, or nil for none.
    public var kv1: KVSetupOptions?

    public init(mount: String = "totp", description: String = "TOTP secrets engine",
                creatorPolicy: String = "totp_creator", userPolicy: String = "totp_user",
                overwritePolicies: Bool = false, engineExists: Bool = false, totp: Bool = true,
                kv: KVSetupOptions? = nil, kv1: KVSetupOptions? = nil) {
        self.mount = mount
        self.description = description
        self.creatorPolicy = creatorPolicy
        self.userPolicy = userPolicy
        self.overwritePolicies = overwritePolicies
        self.engineExists = engineExists
        self.totp = totp
        self.kv = kv
        self.kv1 = kv1
    }
}

/// Prepares a vault for the app: enables the TOTP secrets engine and writes the policies that let
/// users create keys and read codes, and enables KV secrets engines and writes the policies that
/// let users write and read secrets. It assigns no policy to anyone.
public enum VaultSetup {
    /// The policy that lets a user list, create, import and read keys of the engine.
    public static func creatorPolicy(mount: String) -> String {
        let mount = VaultClient.trimmed(mount)
        return """
            path "\(mount)/keys" {
              capabilities = ["list"]
            }

            path "\(mount)/keys/*" {
              capabilities = ["create", "update", "read"]
            }

            """
    }

    /// The policy that lets a user list and read keys, which never return their secrets, and read codes.
    public static func userPolicy(mount: String) -> String {
        let mount = VaultClient.trimmed(mount)
        return """
            path "\(mount)/keys" {
              capabilities = ["list"]
            }

            path "\(mount)/keys/*" {
              capabilities = ["read"]
            }

            path "\(mount)/code/*" {
              capabilities = ["read"]
            }

            """
    }

    /// The policy that lets a user list, create, update and read the secrets of a KV engine.
    public static func kvCreatorPolicy(mount: String, version: KVVersion = .v2) -> String {
        let mount = VaultClient.trimmed(mount)
        if version == .v1 {
            return """
                path "\(mount)/*" {
                  capabilities = ["list", "create", "update", "read"]
                }

                """
        }
        return """
            path "\(mount)/metadata" {
              capabilities = ["list"]
            }

            path "\(mount)/data/*" {
              capabilities = ["create", "update", "patch", "read"]
            }

            """
    }

    /// The policy that lets a user list and read the secrets of a KV engine.
    public static func kvUserPolicy(mount: String, version: KVVersion = .v2) -> String {
        let mount = VaultClient.trimmed(mount)
        if version == .v1 {
            return """
                path "\(mount)/*" {
                  capabilities = ["list", "read"]
                }

                """
        }
        return """
            path "\(mount)/metadata" {
              capabilities = ["list"]
            }

            path "\(mount)/data/*" {
              capabilities = ["read"]
            }

            """
    }

    /// Why the options cannot be used, or nil.
    public static func problem(of options: VaultSetupOptions) -> VaultProblem? {
        func invalid(_ detail: String) -> VaultProblem {
            VaultProblem(kind: .other, title: "A setup setting is not valid", detail: detail,
                         suggestion: "Correct it and run the setup again.")
        }
        func isName(_ value: String) -> Bool {
            !value.isEmpty && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && value.rangeOfCharacter(from: CharacterSet(charactersIn: "?#\"")) == nil
        }
        guard options.totp || options.kv != nil || options.kv1 != nil else {
            return invalid("Nothing is chosen to set up.")
        }
        var mounts: [String] = []
        var policies: [String] = []
        if options.totp {
            mounts.append(VaultClient.trimmed(options.mount))
            policies += [options.creatorPolicy, options.userPolicy]
        }
        for kv in [options.kv, options.kv1].compactMap({ $0 }) {
            mounts.append(VaultClient.trimmed(kv.mount))
            policies += [kv.creatorPolicy, kv.userPolicy]
        }
        if !mounts.allSatisfy(isName) {
            return invalid("A mount is empty or holds spaces or other characters a path cannot hold.")
        }
        if !policies.allSatisfy(isName) {
            return invalid("A policy name is empty or holds spaces or other characters a name cannot hold.")
        }
        if Set(mounts).count != mounts.count {
            return invalid("The two engines need different mounts.")
        }
        if Set(policies).count != policies.count {
            return invalid("The policies need different names.")
        }
        return nil
    }

    /// Runs the calls in order with the client's identity, which is assumed to hold the rights for
    /// them, and stops after the first that fails. Returns the steps that ran.
    public static func run(client: VaultClient, options: VaultSetupOptions) async -> [VaultCheck] {
        if let problem = problem(of: options) {
            return [VaultCheck(step: "Settings", outcome: .failed, message: "The setup was not started.", problem: problem)]
        }
        var parts: [(step: String, label: String, mount: String, body: [String: any Sendable], exists: Bool,
                     policies: [(step: String, name: String, text: String)])] = []
        if options.totp {
            let mount = VaultClient.trimmed(options.mount)
            parts.append(("Engine", "TOTP", mount, ["type": "totp", "description": options.description], options.engineExists,
                          [("Creator policy", options.creatorPolicy, creatorPolicy(mount: mount)),
                           ("User policy", options.userPolicy, userPolicy(mount: mount))]))
        }
        for kv in [options.kv, options.kv1].compactMap({ $0 }) {
            let mount = VaultClient.trimmed(kv.mount)
            let label = "KV v\(kv.version.rawValue)"
            parts.append(("\(label) engine", label, mount,
                          ["type": "kv", "description": kv.description, "options": ["version": String(kv.version.rawValue)]],
                          kv.engineExists,
                          [("\(label) creator policy", kv.creatorPolicy, kvCreatorPolicy(mount: mount, version: kv.version)),
                           ("\(label) user policy", kv.userPolicy, kvUserPolicy(mount: mount, version: kv.version))]))
        }

        var checks: [VaultCheck] = []
        for part in parts {
            // Enable the engine
            if part.exists {
                checks.append(VaultCheck(step: part.step, outcome: .skipped,
                                         message: "The \(part.label) engine is taken as enabled at \(part.mount).", problem: nil))
            } else {
                do {
                    _ = try await client.send("POST", "sys/mounts/\(part.mount)", body: part.body)
                    checks.append(VaultCheck(step: part.step, outcome: .passed,
                                             message: "The \(part.label) engine is enabled at \(part.mount).", problem: nil))
                } catch {
                    checks.append(VaultCheck(step: part.step, outcome: .failed, message: "The engine was not enabled.",
                                             problem: VaultProblem(error)))
                    return checks
                }
            }

            for policy in part.policies {
                let check = await writePolicy(step: policy.step, name: policy.name, text: policy.text, client: client,
                                              overwrite: options.overwritePolicies)
                checks.append(check)
                if check.outcome == .failed {
                    return checks
                }
            }
        }
        return checks
    }

    /// Writes one policy, first refusing a name that exists unless overwriting is allowed.
    private static func writePolicy(step: String, name: String, text: String, client: VaultClient,
                                    overwrite: Bool) async -> VaultCheck {
        if !overwrite {
            do {
                _ = try await client.send("GET", "sys/policies/acl/\(name)")
                return VaultCheck(step: step, outcome: .failed, message: "A policy named \(name) exists already.",
                                  problem: VaultProblem(kind: .other, title: "The policy exists",
                                                        detail: "The vault holds a policy named \(name), and writing it would replace it.",
                                                        suggestion: "Allow the setup to replace existing policies, or choose another name."))
            } catch VaultError.http(let status, _) where status == 404 {
                // The name is free.
            } catch {
                return VaultCheck(step: step, outcome: .failed, message: "The policy \(name) could not be looked up.",
                                  problem: VaultProblem(error))
            }
        }
        do {
            _ = try await client.send("PUT", "sys/policies/acl/\(name)", body: ["policy": text])
            return VaultCheck(step: step, outcome: .passed, message: "The policy \(name) is written.", problem: nil)
        } catch {
            return VaultCheck(step: step, outcome: .failed, message: "The policy \(name) was not written.",
                              problem: VaultProblem(error))
        }
    }
}
