import SwiftUI
import Vault

/// The Vault Setup dialog: the engine mount and the policy names, and the run, as the identity the
/// vault's page describes.
struct VaultSetupSheet: View {
    let draft: VaultProfileDraft
    let session: VaultSession?
    @Environment(\.dismiss) private var dismiss
    @State private var options: VaultSetupOptions
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
        let options = options
        Task {
            do {
                let configuration = try draft.configuration()
                if configuration.authMethod == .oidc {
                    guard let session else {
                        throw VaultError.notSignedIn
                    }
                    checks = try await session.authorized { await VaultSetup.run(client: $0, options: options) }
                } else {
                    let credential = draft.credential.isEmpty
                        ? try session.flatMap { try Keychain.vaultCredential(of: $0.profile.id) } : draft.credential
                    guard let token = try await VaultClient.signIn(configuration: configuration, credential: credential) else {
                        throw VaultError.notSignedIn
                    }
                    checks = await VaultSetup.run(client: VaultClient(configuration: configuration, token: token.token),
                                                  options: options)
                }
            } catch {
                checks = [VaultCheck(step: "Sign-in", outcome: .failed, message: "The setup was not started.",
                                     problem: VaultProblem(error))]
            }
            running = false
            finished = true
        }
    }

    var body: some View {
        Form {
            Section("Engine") {
                TextField("TOTP engine mount", text: $options.mount)
                TextField("Description", text: $options.description)
                Toggle("The engine is already enabled", isOn: $options.engineExists)
            }
            Section("Policies") {
                TextField("Creator policy", text: $options.creatorPolicy)
                TextField("User policy", text: $options.userPolicy)
                Toggle("Replace policies that exist", isOn: $options.overwritePolicies)
                Text("The policies are not assigned to anyone; a Vault administrator assigns them to users, roles or tokens.")
                    .foregroundStyle(.secondary)
            }
            Section("Creator policy text") {
                Text(VaultSetup.creatorPolicy(mount: options.mount))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("User policy text") {
                Text(VaultSetup.userPolicy(mount: options.mount))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
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
