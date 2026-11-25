import Foundation

/// What the setup of a vault is asked to do.
public struct VaultSetupOptions: Equatable, Sendable {
    public var mount: String
    public var description: String
    public var creatorPolicy: String
    public var userPolicy: String
    /// Replace policies of these names that exist; otherwise the setup stops at one.
    public var overwritePolicies: Bool
    /// The engine is enabled already, so only the policies are written.
    public var engineExists: Bool

    public init(mount: String = "totp", description: String = "TOTP secrets engine",
                creatorPolicy: String = "totp_creator", userPolicy: String = "totp_user",
                overwritePolicies: Bool = false, engineExists: Bool = false) {
        self.mount = mount
        self.description = description
        self.creatorPolicy = creatorPolicy
        self.userPolicy = userPolicy
        self.overwritePolicies = overwritePolicies
        self.engineExists = engineExists
    }
}

/// Prepares a vault for the app: enables the TOTP secrets engine and writes the policies that let
/// users create keys and read codes. It assigns no policy to anyone.
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

    /// Why the options cannot be used, or nil.
    public static func problem(of options: VaultSetupOptions) -> VaultProblem? {
        func invalid(_ detail: String) -> VaultProblem {
            VaultProblem(kind: .other, title: "A setup setting is not valid", detail: detail,
                         suggestion: "Correct it in the setup dialog.")
        }
        func isName(_ value: String) -> Bool {
            !value.isEmpty && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && value.rangeOfCharacter(from: CharacterSet(charactersIn: "?#\"")) == nil
        }
        if !isName(VaultClient.trimmed(options.mount)) {
            return invalid("The mount is empty or holds spaces or other characters a path cannot hold.")
        }
        if !isName(options.creatorPolicy) || !isName(options.userPolicy) {
            return invalid("A policy name is empty or holds spaces or other characters a name cannot hold.")
        }
        if options.creatorPolicy == options.userPolicy {
            return invalid("The two policies need different names.")
        }
        return nil
    }

    /// Runs the calls in order with the client's identity, which is assumed to hold the rights for
    /// them, and stops after the first that fails. Returns the steps that ran.
    public static func run(client: VaultClient, options: VaultSetupOptions) async -> [VaultCheck] {
        if let problem = problem(of: options) {
            return [VaultCheck(step: "Settings", outcome: .failed, message: "The setup was not started.", problem: problem)]
        }
        var checks: [VaultCheck] = []
        let mount = VaultClient.trimmed(options.mount)

        // Enable the engine
        if options.engineExists {
            checks.append(VaultCheck(step: "Engine", outcome: .skipped, message: "The engine is taken as enabled at \(mount).",
                                     problem: nil))
        } else {
            do {
                _ = try await client.send("POST", "sys/mounts/\(mount)",
                                          body: ["type": "totp", "description": options.description])
                checks.append(VaultCheck(step: "Engine", outcome: .passed, message: "The TOTP engine is enabled at \(mount).",
                                         problem: nil))
            } catch {
                checks.append(VaultCheck(step: "Engine", outcome: .failed, message: "The engine was not enabled.",
                                         problem: VaultProblem(error)))
                return checks
            }
        }

        let policies = [("Creator policy", options.creatorPolicy, creatorPolicy(mount: mount)),
                        ("User policy", options.userPolicy, userPolicy(mount: mount))]
        for (step, name, text) in policies {
            let check = await writePolicy(step: step, name: name, text: text, client: client,
                                          overwrite: options.overwritePolicies)
            checks.append(check)
            if check.outcome == .failed {
                return checks
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
                                                        suggestion: "Tick Replace policies that exist, or choose another name."))
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
