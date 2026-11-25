import SwiftUI
import TOTP
import Vault

/// The content of the Settings window: the accounts, and the Vault profiles with their keys.
struct SettingsView: View {
    let store: AccountStore
    let windows: CodeWindows
    @Bindable var router: SettingsRouter

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Accounts", systemImage: "list.bullet", value: SettingsRouter.Tab.accounts) {
                AccountsSettings(store: store, windows: windows, router: router)
            }
            Tab("Vaults", systemImage: "lock.shield", value: SettingsRouter.Tab.vaults) {
                VaultSettings(store: store, windows: windows, router: router)
            }
        }
        .scenePadding()
        .frame(minWidth: 700, minHeight: 460)
    }
}

/// The registered accounts: a list to add to and remove from, and the details of the selected one.
struct AccountsSettings: View {
    let store: AccountStore
    let windows: CodeWindows
    let router: SettingsRouter
    @State private var selection: UUID?

    private var selectedAccount: Account? {
        store.accounts.first { $0.id == selection }
    }

    /// The store of an account's secret: the keychain, or the vault that makes its codes.
    private func source(of account: Account) -> String {
        guard let vaultKey = store.vaultKeys[account.id] else {
            return "Keychain"
        }
        return "Vault: \(store.vault(for: vaultKey.profile)?.profile.name ?? "removed")"
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let loadError = store.loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                        .padding(8)
                    Button("Retry") {
                        store.reload()
                    }
                }
                List(store.accounts, selection: $selection) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(source(of: account))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.problem(of: account) != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .tag(account.id)
                }
                HStack {
                    Menu {
                        Button("Account...") {
                            Dialogs.addAccount(to: store)
                        }
                        Button("From QR Code in Clipboard") {
                            Dialogs.addAccountFromClipboard(to: store)
                        }
                        Divider()
                        Button("From Vault...") {
                            Task {
                                await Dialogs.addFromVault(to: store)
                            }
                        }
                        .disabled(store.vaults.isEmpty)
                        Button("Generate in Vault...") {
                            Task {
                                await Dialogs.generateAccount(to: store)
                            }
                        }
                        .disabled(store.vaults.isEmpty)
                        Button("Import to Vault...") {
                            Task {
                                await Dialogs.importAccount(to: store)
                            }
                        }
                        .disabled(store.vaults.isEmpty)
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    Button("Remove Account", systemImage: "minus") {
                        if let account = selectedAccount {
                            Dialogs.removeAccount(account, from: store)
                            windows.closeRemoved()
                        }
                    }
                    .disabled(selectedAccount == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            if let account = selectedAccount {
                AccountDetails(store: store, windows: windows, router: router, account: account, source: source(of: account))
                    .id(account.id)
                    .frame(minWidth: 380)
            } else {
                Text("Select an account, or add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The parameters of an account and what can be done with it.
private struct AccountDetails: View {
    let store: AccountStore
    let windows: CodeWindows
    let router: SettingsRouter
    let account: Account
    let source: String

    var body: some View {
        Form {
            if let problem = store.problem(of: account) {
                Section("Problem") {
                    Text(problem.title)
                        .foregroundStyle(.red)
                    Text(problem.detail)
                    Text(problem.suggestion)
                        .foregroundStyle(.secondary)
                    if let profile = store.vaultKeys[account.id]?.profile, store.vault(for: profile) != nil {
                        Button("Show Vault") {
                            router.vault = profile
                            router.tab = .vaults
                        }
                    }
                }
            }
            Section("Account") {
                LabeledContent("Name", value: account.name)
                if let issuer = account.issuer {
                    LabeledContent("Issuer", value: issuer)
                }
                LabeledContent("Store", value: source)
                if let key = store.vaultKeys[account.id]?.key {
                    LabeledContent("Vault key", value: key)
                }
            }
            Section("Code") {
                LabeledContent("Algorithm", value: account.algorithm.rawValue)
                LabeledContent("Digits", value: String(account.digits))
                LabeledContent("Period", value: "\(account.period) s")
            }
            Section {
                Toggle("Show in menu bar", isOn: Binding(
                    get: { store.menuBarAccountID == account.id },
                    set: { store.setShownInMenuBar(account, $0) }
                ))
                HStack {
                    Button("Show Window") {
                        windows.show(account)
                    }
                    Button("Copy Code") {
                        Task {
                            do {
                                try await store.copyCode(of: account)
                            } catch {
                                Dialogs.showProblem("The code was not copied", error)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// What the Vault list has selected: a saved profile, or the new one being made.
private enum VaultSelection: Hashable {
    case profile(UUID)
    case new
}

/// The Vault profiles, and the settings, authentication and keys of the selected one.
struct VaultSettings: View {
    let store: AccountStore
    let windows: CodeWindows
    @Bindable var router: SettingsRouter
    @State private var selection: VaultSelection?

    private var selectedSession: VaultSession? {
        guard case let .profile(id) = selection else {
            return nil
        }
        return store.vault(for: id)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.vaults, id: \.profile.id) { session in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(session.status.color)
                            Text(session.profile.name)
                        }
                        .tag(VaultSelection.profile(session.profile.id))
                    }
                    if selection == .new {
                        Label("New vault", systemImage: "plus.circle")
                            .tag(VaultSelection.new)
                    }
                }
                HStack {
                    Button("Add Vault", systemImage: "plus") {
                        selection = .new
                    }
                    Button("Remove Vault", systemImage: "minus") {
                        if let session = selectedSession {
                            Dialogs.removeVaultProfile(session, from: store)
                            windows.closeRemoved()
                            if store.vault(for: session.profile.id) == nil {
                                selection = nil
                            }
                        }
                    }
                    .disabled(selectedSession == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)

            if selection == .new || selectedSession != nil {
                VaultProfileEditor(store: store, session: selectedSession) { id in
                    selection = .profile(id)
                }
                .id(selection)
                .frame(minWidth: 380)
            } else {
                Text("Select a vault, or add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: router.vault, initial: true) { _, id in
            if let id {
                selection = .profile(id)
                router.vault = nil
            }
        }
    }
}

extension VaultSession.Status {
    /// The colour of the status dot of a profile.
    fileprivate var color: Color {
        switch self {
        case .signedIn:
            return .green
        case .signingIn:
            return .yellow
        case .failed:
            return .red
        case .signedOut:
            return .gray
        }
    }

    /// The status in the words of the method: a token is checked, a password or an AppRole is logged
    /// in, and only OIDC signs in.
    fileprivate func text(for method: AuthMethod) -> String {
        switch (self, method) {
        case let (.failed(problem), _):
            return problem.title
        case (.signedOut, .token):
            return "Token not checked"
        case (.signedOut, .userpass), (.signedOut, .approle):
            return "Not logged in"
        case (.signedOut, .oidc):
            return "Signed out"
        case (.signingIn, .token):
            return "Checking the token..."
        case (.signingIn, .userpass), (.signingIn, .approle):
            return "Logging in..."
        case (.signingIn, .oidc):
            return "Signing in..."
        case (.signedIn, .token):
            return "Token accepted"
        case (.signedIn, .userpass), (.signedIn, .approle):
            return "Logged in"
        case (.signedIn, .oidc):
            return "Signed in"
        }
    }
}

extension AuthMethod {
    fileprivate var title: String {
        switch self {
        case .token:
            return "Token"
        case .userpass:
            return "Username and password"
        case .approle:
            return "AppRole"
        case .oidc:
            return "OIDC"
        }
    }

    /// The name of the action that starts the method: a token is checked, a password or an AppRole is
    /// logged in, and OIDC signs in.
    fileprivate var startLabel: String {
        switch self {
        case .token:
            return "Check Token"
        case .userpass, .approle:
            return "Log In"
        case .oidc:
            return "Sign In"
        }
    }

    /// The name of the action that drops what the method obtained.
    fileprivate var stopLabel: String {
        switch self {
        case .token:
            return "Forget Token"
        case .userpass, .approle:
            return "Log Out"
        case .oidc:
            return "Sign Out"
        }
    }

    /// What the credential of the method is called; OIDC has none.
    fileprivate var credentialLabel: String {
        switch self {
        case .userpass:
            return "Password"
        case .approle:
            return "SecretID"
        default:
            return "Token"
        }
    }
}

/// The fields of a Vault profile as typed.
struct VaultProfileDraft: Equatable {
    var name = ""
    var address = ""
    var namespace = ""
    var totpMount = "totp"
    var method = AuthMethod.token
    var authMount = AuthMethod.token.rawValue
    var username = ""
    var roleID = ""
    var oidcRole = ""
    var oidcPort = "8250"
    var credential = ""

    init() {}

    init(_ profile: VaultProfile) {
        let configuration = profile.configuration
        name = profile.name
        address = configuration.address
        namespace = configuration.namespace ?? ""
        totpMount = configuration.totpMount
        method = configuration.authMethod
        authMount = configuration.authMount
        username = configuration.username ?? ""
        roleID = configuration.roleID ?? ""
        oidcRole = configuration.oidcRole ?? ""
        oidcPort = String(configuration.oidcPort)
    }

    /// The settings in the fields, or why they cannot be used.
    func configuration() throws -> VaultConfiguration {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let address = text(address) else {
            throw SessionError.missingSetting("Vault address")
        }
        guard let port = Int(oidcPort), (1 ... 65535).contains(port) else {
            throw SessionError.invalidSetting("Redirect URI port")
        }
        if method == .userpass, text(username) == nil {
            throw SessionError.missingSetting("Username")
        }
        if method == .approle, text(roleID) == nil {
            throw SessionError.missingSetting("RoleID")
        }
        return VaultConfiguration(address: address, namespace: text(namespace), totpMount: text(totpMount) ?? "totp",
                                  authMethod: method, authMount: text(authMount), username: text(username),
                                  roleID: text(roleID), oidcRole: text(oidcRole), oidcPort: port)
    }
}

/// The page of a vault: its settings and authentication, and for a saved one its accounts; the session is
/// nil for a vault not yet made.
private struct VaultProfileEditor: View {
    let store: AccountStore
    let session: VaultSession?
    let saved: (UUID) -> Void
    @State private var draft: VaultProfileDraft
    @State private var message: String?
    @State private var checks: [VaultCheck] = []
    @State private var testing = false
    @State private var showSetup = false

    init(store: AccountStore, session: VaultSession?, saved: @escaping (UUID) -> Void) {
        self.store = store
        self.session = session
        self.saved = saved
        _draft = State(initialValue: session.map { VaultProfileDraft($0.profile) } ?? VaultProfileDraft())
    }

    /// Writes the profile, and signs in at once, except for OIDC, which is signed in on request.
    private func save() {
        do {
            let configuration = try draft.configuration()
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            let credential = draft.credential
            let profile: VaultSession
            if let session {
                try store.updateVaultProfile(session, name: name, configuration: configuration,
                                             credential: credential.isEmpty ? nil : credential)
                profile = session
            } else {
                profile = try store.addVaultProfile(name: name, configuration: configuration, credential: credential)
            }
            message = nil
            draft.credential = ""
            saved(profile.profile.id)
            if configuration.authMethod != .oidc {
                Task {
                    // The vault's status shows the outcome.
                    try? await store.signInToVault(profile)
                }
            }
        } catch {
            message = VaultProblem(error).report
        }
    }

    /// Tests the vault as the form describes it, with the stored credential when none is typed.
    private func test() {
        testing = true
        checks = []
        Task {
            do {
                let configuration = try draft.configuration()
                let credential = draft.credential.isEmpty
                    ? try session.flatMap { try Keychain.vaultCredential(of: $0.profile.id) } : draft.credential
                checks = await VaultDiagnostics.run(configuration: configuration, credential: credential)
            } catch {
                checks = [VaultCheck(step: "Settings", outcome: .failed, message: "The settings cannot be tested.",
                                     problem: VaultProblem(error))]
            }
            testing = false
        }
    }

    var body: some View {
        Form {
            Section("Vault") {
                TextField("Name", text: $draft.name, prompt: Text("For example Work or Lab"))
                TextField("Vault address", text: $draft.address, prompt: Text("https://vault.example.com:8200"))
                TextField("Namespace", text: $draft.namespace, prompt: Text("Optional, Vault Enterprise"))
                TextField("TOTP engine mount", text: $draft.totpMount)
            }
            Section("Authentication") {
                Picker("Method", selection: $draft.method) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.title)
                    }
                }
                .onChange(of: draft.method) { _, method in
                    if draft.authMount.isEmpty || AuthMethod(rawValue: draft.authMount) != nil {
                        draft.authMount = method.rawValue
                    }
                }
                if draft.method != .token {
                    TextField("Auth method mount", text: $draft.authMount)
                }
                if draft.method == .userpass {
                    TextField("Username", text: $draft.username)
                }
                if draft.method == .approle {
                    TextField("RoleID", text: $draft.roleID)
                }
                if draft.method == .oidc {
                    TextField("OIDC role", text: $draft.oidcRole, prompt: Text("Empty for the default role"))
                    TextField("Redirect URI port", text: $draft.oidcPort)
                } else {
                    SecureField(draft.method.credentialLabel, text: $draft.credential,
                                prompt: Text(session == nil ? "" : "Empty keeps the stored one"))
                }
                if let session {
                    LabeledContent("Status") {
                        Text(session.status.text(for: session.configuration.authMethod))
                            .foregroundStyle(session.status.color)
                    }
                    if case let .failed(problem) = session.status {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem.detail)
                            Text(problem.suggestion)
                                .foregroundStyle(.secondary)
                        }
                        if let last = session.lastAttempt {
                            LabeledContent("Last attempt", value: last.formatted(date: .omitted, time: .standard))
                        }
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(session.profile.name)\n\(problem.report)", forType: .string)
                        }
                    }
                    HStack {
                        Button(session.configuration.authMethod.startLabel) {
                            Task {
                                // The vault's status shows the outcome.
                                try? await store.signInToVault(session)
                            }
                        }
                        .disabled(session.status == .signingIn)
                        Button(session.configuration.authMethod.stopLabel) {
                            store.signOutOfVault(session)
                        }
                        .disabled(session.status == .signedOut)
                    }
                }
                HStack {
                    Button("Test Connection") {
                        test()
                    }
                    .disabled(testing)
                    Button("Vault Setup...") {
                        showSetup = true
                    }
                    .disabled(draft.address.trimmingCharacters(in: .whitespaces).isEmpty)
                    if testing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                ForEach(checks.indices, id: \.self) { index in
                    CheckRow(check: checks[index])
                }
            }
            Section {
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Revert") {
                        draft = session.map { VaultProfileDraft($0.profile) } ?? VaultProfileDraft()
                        message = nil
                    }
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSetup) {
            VaultSetupSheet(draft: draft, session: session)
        }
    }
}


/// One step of a connection test or a setup: its outcome, its message, and what to do when it is not passed.
struct CheckRow: View {
    let check: VaultCheck

    private var symbol: (name: String, color: Color) {
        switch check.outcome {
        case .passed:
            return ("checkmark.circle.fill", .green)
        case .warning:
            return ("exclamationmark.triangle.fill", .yellow)
        case .failed:
            return ("xmark.octagon.fill", .red)
        case .skipped:
            return ("minus.circle", .gray)
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.step)
                    .bold()
                Text(check.message)
                if let problem = check.problem {
                    Text(problem.detail)
                    Text(problem.suggestion)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
