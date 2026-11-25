import SwiftUI
import Vault

/// The Vault Setup dialog: the TOTP engine and KV v2 and v1 engines for secrets, their mounts and
/// policy names, and the run, as the identity the vault's page describes.
struct VaultSetupSheet: View {
    let draft: VaultProfileDraft
    let session: VaultSession?
    @Environment(\.dismiss) private var dismiss
    @State private var options: VaultSetupOptions
    @State private var kvEnabled = false
    @State private var kv = KVSetupOptions()
    @State private var kv1Enabled = false
    @State private var kv1 = KVSetupOptions(version: .v1)
    @State private var checks: [VaultCheck] = []
    @State private var running = false
    @State private var finished = false

    init(draft: VaultProfileDraft, session: VaultSession?) {
        self.draft = draft
        self.session = session
        _options = State(initialValue: VaultSetupOptions(mount: draft.totpMount.isEmpty ? "totp" : draft.totpMount))
    }

    /// Signs in as the page describes, which for OIDC is the vault's current sign-in, and runs the setup.
    private func run() {
        running = true
        checks = []
        var options = options
        options.kv = kvEnabled ? kv : nil
        options.kv1 = kv1Enabled ? kv1 : nil
        let setup = options
        Task {
            do {
                let configuration = try draft.configuration()
                if configuration.authMethod == .oidc {
                    guard let session else {
                        throw VaultError.notSignedIn
                    }
                    checks = try await session.authorized { await VaultSetup.run(client: $0, options: setup) }
                } else {
                    let credential = draft.credential.isEmpty
                        ? try session.flatMap { try Keychain.vaultCredential(of: $0.profile.id) } : draft.credential
                    guard let token = try await VaultClient.signIn(configuration: configuration, credential: credential) else {
                        throw VaultError.notSignedIn
                    }
                    checks = await VaultSetup.run(client: VaultClient(configuration: configuration, token: token.token),
                                                  options: setup)
                }
            } catch {
                checks = [VaultCheck(step: "Authentication", outcome: .failed, message: "The setup was not started.",
                                     problem: VaultProblem(error, method: draft.method))]
            }
            running = false
            finished = true
        }
    }

    var body: some View {
        Form {
            Section("TOTP engine") {
                Toggle("Set up the TOTP engine", isOn: $options.totp)
                if options.totp {
                    TextField("TOTP engine mount", text: $options.mount)
                    TextField("Description", text: $options.description)
                    Toggle("The engine is already enabled", isOn: $options.engineExists)
                    TextField("Creator policy", text: $options.creatorPolicy)
                    TextField("User policy", text: $options.userPolicy)
                }
            }
            Section("KV v2 engine") {
                Toggle("Set up a KV v2 engine for secrets", isOn: $kvEnabled)
                if kvEnabled {
                    TextField("KV v2 engine mount", text: $kv.mount)
                    TextField("Description", text: $kv.description)
                    Toggle("The engine is already enabled", isOn: $kv.engineExists)
                    TextField("KV v2 secret creator policy", text: $kv.creatorPolicy)
                    TextField("KV v2 secret user policy", text: $kv.userPolicy)
                }
            }
            Section("KV v1 engine") {
                Toggle("Set up a KV v1 engine for secrets", isOn: $kv1Enabled)
                if kv1Enabled {
                    TextField("KV v1 engine mount", text: $kv1.mount)
                    TextField("Description", text: $kv1.description)
                    Toggle("The engine is already enabled", isOn: $kv1.engineExists)
                    TextField("KV v1 secret creator policy", text: $kv1.creatorPolicy)
                    TextField("KV v1 secret user policy", text: $kv1.userPolicy)
                }
            }
            Section("Policies") {
                Toggle("Replace policies that exist", isOn: $options.overwritePolicies)
                Text("The policies are not assigned to anyone; a Vault administrator assigns them to users, roles or tokens.")
                    .foregroundStyle(.secondary)
            }
            if options.totp {
                Section("TOTP creator policy text") {
                    Text(VaultSetup.creatorPolicy(mount: options.mount))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("TOTP user policy text") {
                    Text(VaultSetup.userPolicy(mount: options.mount))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if kvEnabled {
                Section("KV v2 secret creator policy text") {
                    Text(VaultSetup.kvCreatorPolicy(mount: kv.mount))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("KV v2 secret user policy text") {
                    Text(VaultSetup.kvUserPolicy(mount: kv.mount))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if kv1Enabled {
                Section("KV v1 secret creator policy text") {
                    Text(VaultSetup.kvCreatorPolicy(mount: kv1.mount, version: .v1))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("KV v1 secret user policy text") {
                    Text(VaultSetup.kvUserPolicy(mount: kv1.mount, version: .v1))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if running || !checks.isEmpty {
                Section("Result") {
                    if running {
                        ProgressView()
                            .controlSize(.small)
                    }
                    ForEach(checks.indices, id: \.self) { index in
                        CheckRow(check: checks[index])
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(finished ? "Close" : "Cancel", role: .cancel) {
                        dismiss()
                    }
                    Button(finished ? "Run Again" : "Run") {
                        run()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }
}
