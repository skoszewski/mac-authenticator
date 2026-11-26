import AppKit
import LocalAuthentication
import Observation
import ServiceManagement
import TOTP
import Vault

/// Why the account list was not changed.
enum StoreError: LocalizedError {
    case duplicateName(String)
    case duplicateProfileName(String)
    case missingProfileName
    case profileRemoved
    case notLoaded
    case referenceMissing
    case recordsUnreadable(String)
    case missingName
    case emptySecret

    var errorDescription: String? {
        switch self {
        case .missingName:
            return "Give the account a name."
        case .emptySecret:
            return "The secret is empty."
        case let .duplicateName(name):
            return "An account named \(name) exists already."
        case let .duplicateProfileName(name):
            return "A vault named \(name) exists already."
        case .missingProfileName:
            return "Give the vault a name."
        case .profileRemoved:
            return "The vault of this account was removed."
        case .notLoaded:
            return "The accounts were not read completely, so they are not changed."
        case let .recordsUnreadable(reason):
            return "The stored records of the Vault accounts could not be read, and are left as they are: \(reason)"
        case .referenceMissing:
            return "The record of this account holds no reference to a secret."
        }
    }
}

/// The profile and the name of the key an account whose codes Vault makes is read from.
struct VaultKey: Equatable {
    var profile: UUID
    var key: String
}

/// The profile and the reference of the KV secret field a secret account is read from.
struct VaultSecret: Equatable {
    var profile: UUID
    var reference: SecretReference
}

/// An account kept in Vault: for an OTP account the parameters, the profile and the name of the
/// key Vault makes its codes from; for a secret account the profile and the reference, with the
/// parameters and the key empty. Records written before secret accounts have neither kind nor reference.
private struct VaultRecord: Codable {
    var id: UUID
    var kind: Account.Kind?
    var profile: UUID
    var name: String
    var issuer: String?
    var parameters: String
    var key: String
    var reference: SecretReference?
    /// Whether the secret account asks the user to authenticate; absent means it does.
    var authenticate: Bool?
    var added: Date
}

/// A vault that needs the user's attention, and why.
struct VaultIssue: Identifiable {
    let id: UUID
    let session: VaultSession
    let problem: VaultProblem
}

/// A code fetched from Vault, with the period count it is valid for.
private struct VaultCode {
    var code: String
    var counter: Int
}

/// The registered accounts, the secrets of those whose codes are shown, and the clock the codes
/// are shown for.
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    /// Called when a vault that worked fails.
    @ObservationIgnored var vaultProblemHandler: ((VaultSession, VaultProblem) -> Void)?
    /// Called after a vault is saved.
    @ObservationIgnored var vaultSaved: (() -> Void)?
    /// The sessions of the Vault profiles, in the order the profiles were created.
    private(set) var vaults: [VaultSession] = []
    /// The Vault key and profile of each account whose codes Vault makes.
    private(set) var vaultKeys: [UUID: VaultKey] = [:]
    /// The Vault profile and KV field of each secret account kept in Vault.
    private(set) var vaultSecrets: [UUID: VaultSecret] = [:]
    private var vaultCodes: [UUID: VaultCode] = [:]
    @ObservationIgnored private var vaultRecords: [VaultRecord] = []
    /// The accounts of records that name no KV reference although they are secret accounts.
    @ObservationIgnored private var brokenRecords: Set<UUID> = []
    /// The accounts being fetched, and the period count of the last failed fetch of each.
    @ObservationIgnored private var vaultFetching: Set<UUID> = []
    @ObservationIgnored private var vaultFailures: [UUID: Int] = [:]
    /// Why the keychain could not be listed; changes are refused while it is set.
    private(set) var loadError: String?
    /// The current time, advanced at each whole second.
    private(set) var now = Date()
    /// The account whose code is shown beside the menu bar icon, kept in the user defaults.
    private(set) var menuBarAccountID: UUID? = UserDefaults.standard.string(forKey: "menuBarAccount")
        .flatMap(UUID.init(uuidString:)) {
        didSet {
            UserDefaults.standard.set(menuBarAccountID?.uuidString, forKey: "menuBarAccount")
            updateSecrets()
        }
    }
    /// The accounts whose code windows are open.
    private(set) var openWindowIDs: Set<UUID> = []
    /// Why the secret of a shown account could not be read.
    private(set) var secretErrors: [UUID: String] = [:]
    /// Whether the app is registered as a login item.
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// The secrets of the accounts whose codes are shown, and of no other.
    @ObservationIgnored private var secrets: [UUID: String] = [:]
    @ObservationIgnored private var timer: Timer?
    /// The change count of the clipboard right after a secret was copied to it.
    @ObservationIgnored private var copiedSecret: Int?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    var menuBarAccount: Account? {
        accounts.first { $0.id == menuBarAccountID }
    }

    init() {
        UserDefaults.standard.removeObject(forKey: "vault")
        UserDefaults.standard.removeObject(forKey: "vaultAccounts")
        Keychain.deleteLegacyVaultCredential()
        reload()
        let start = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970))
        let timer = Timer(fire: start, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                self?.refreshVaultCodes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearCopiedSecret()
            }
        }
    }

    /// Lists the Vault profiles and the accounts from the keychain again, in the stored menu order;
    /// accounts missing from the order follow by the creation of their items. The session of a
    /// profile that is still there is kept, with its token.
    func reload() {
        do {
            vaultRecords = try Self.readVaultRecords()
            brokenRecords = Set(vaultRecords.filter { $0.kind == .secret && $0.reference == nil }.map(\.id))
            vaults = try Keychain.vaultProfiles().map { profile in
                let session = vaults.first(where: { $0.profile.id == profile.id }) ?? VaultSession(profile: profile)
                if session.profile != profile {
                    session.update(profile)
                }
                session.onProblem = { [weak self] session, problem in
                    self?.vaultProblemHandler?(session, problem)
                }
                return session
            }
            let order = UserDefaults.standard.stringArray(forKey: "accountOrder") ?? []
            let vaultListed = vaultRecords.compactMap { record in
                let account = record.kind == .secret
                    ? Account(secretID: record.id, name: record.name, requiresAuthentication: record.authenticate ?? true)
                    : try? Account(id: record.id, name: record.name, issuer: record.issuer, parameters: record.parameters)
                return account.map { Keychain.Listed(account: $0, created: record.added) }
            }
            let otpRecords = vaultRecords.filter { $0.kind != .secret }
            vaultKeys = Dictionary(uniqueKeysWithValues: otpRecords.map { ($0.id, VaultKey(profile: $0.profile, key: $0.key)) })
            vaultSecrets = Dictionary(uniqueKeysWithValues: vaultRecords.compactMap { record in
                record.reference.map { (record.id, VaultSecret(profile: record.profile, reference: $0)) }
            })
            let listed = try Keychain.accounts() + Keychain.secretAccounts() + vaultListed
            accounts = listed.sorted { first, second in
                let firstIndex = order.firstIndex(of: first.account.id.uuidString) ?? Int.max
                let secondIndex = order.firstIndex(of: second.account.id.uuidString) ?? Int.max
                return firstIndex != secondIndex ? firstIndex < secondIndex : first.created < second.created
            }.map(\.account)
            loadError = nil
            saveOrder()
        } catch {
            accounts = []
            loadError = error.localizedDescription
        }
        updateSecrets()
    }

    /// Adds the account's keychain item and appends it to the list, refusing a name already in it.
    func add(_ new: NewAccount) throws {
        try checkCanAdd(named: new.account.name)
        try Keychain.add(new)
        accounts.append(new.account)
        saveOrder()
    }

    /// Adds an account whose codes the Vault profile makes from the key; nothing secret is kept
    /// for it.
    func addVaultAccount(_ account: Account, key: String, profile: UUID) throws {
        try checkCanAdd(named: account.name)
        vaultRecords.append(VaultRecord(id: account.id, kind: nil, profile: profile, name: account.name, issuer: account.issuer,
                                        parameters: account.parameters, key: key, reference: nil, authenticate: nil,
                                        added: Date()))
        saveVaultRecords()
        vaultKeys[account.id] = VaultKey(profile: profile, key: key)
        accounts.append(account)
        saveOrder()
    }

    /// Adds a secret account whose secret is kept in the keychain.
    func addSecret(name: String, value: String, requiresAuthentication: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw StoreError.missingName
        }
        guard !value.isEmpty else {
            throw StoreError.emptySecret
        }
        try checkCanAdd(named: name)
        let account = Account(secretID: UUID(), name: name, requiresAuthentication: requiresAuthentication)
        try Keychain.addSecret(id: account.id, name: name, value: value, requiresAuthentication: requiresAuthentication)
        accounts.append(account)
        saveOrder()
    }

    /// Adds a secret account read from a field of a KV secret of the Vault profile; nothing secret
    /// is kept for it.
    func addVaultSecret(name: String, reference: SecretReference, profile: UUID, requiresAuthentication: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw StoreError.missingName
        }
        try checkCanAdd(named: name)
        let account = Account(secretID: UUID(), name: name, requiresAuthentication: requiresAuthentication)
        vaultRecords.append(VaultRecord(id: account.id, kind: .secret, profile: profile, name: name, issuer: nil,
                                        parameters: "", key: "", reference: reference,
                                        authenticate: requiresAuthentication, added: Date()))
        saveVaultRecords()
        vaultSecrets[account.id] = VaultSecret(profile: profile, reference: reference)
        accounts.append(account)
        saveOrder()
    }

    /// The session of the Vault profile, or nil when it is gone.
    func vault(for profile: UUID) -> VaultSession? {
        vaults.first { $0.profile.id == profile }
    }

    /// Refuses an empty name, and one another profile has.
    private func checkProfileName(_ name: String, excluding id: UUID?) throws {
        guard !name.isEmpty else {
            throw StoreError.missingProfileName
        }
        if vaults.contains(where: { $0.profile.id != id && $0.profile.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw StoreError.duplicateProfileName(name)
        }
    }

    /// Adds the profile's keychain item, with its credential, and its session. An OIDC profile
    /// keeps no credential.
    func addVaultProfile(name: String, configuration: VaultConfiguration, credential: String) throws -> VaultSession {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        try checkProfileName(name, excluding: nil)
        let profile = VaultProfile(id: UUID(), name: name, configuration: configuration)
        try Keychain.addVaultProfile(profile, credential: configuration.authMethod == .oidc ? "" : credential)
        vaultSaved?()
        reload()
        return vault(for: profile.id) ?? VaultSession(profile: profile)
    }

    /// Replaces the profile's name and settings, and its credential when one is given; an OIDC
    /// profile's credential is deleted. The token of an OIDC sign-in is kept, unless the user chose to
    /// delete it.
    func updateVaultProfile(_ session: VaultSession, name: String, configuration: VaultConfiguration,
                            credential: String?, deleteToken: Bool = false) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        try checkProfileName(name, excluding: session.profile.id)
        let profile = VaultProfile(id: session.profile.id, name: name, configuration: configuration)
        try Keychain.updateVaultProfile(profile, credential: configuration.authMethod == .oidc ? "" : credential)
        session.update(profile)
        if deleteToken {
            session.signOut()
        }
        vaultConnectionChanged()
        reload()
    }

    /// The accounts kept in the Vault profile: those whose codes it makes and those whose secret it holds.
    func accounts(of profile: UUID) -> [Account] {
        accounts.filter { vaultProfile(of: $0) == profile }
    }

    /// The Vault profile an account is kept in; nil for a keychain account.
    func vaultProfile(of account: Account) -> UUID? {
        vaultKeys[account.id]?.profile ?? vaultSecrets[account.id]?.profile
    }

    /// Deletes the profile's keychain item and its accounts; their keys stay in Vault.
    func removeVaultProfile(_ session: VaultSession) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        let id = session.profile.id
        try Keychain.deleteVaultProfile(id)
        session.signOut()
        vaultRecords.removeAll { $0.profile == id }
        saveVaultRecords()
        reload()
        if let shown = menuBarAccountID, !accounts.contains(where: { $0.id == shown }) {
            menuBarAccountID = nil
        }
        openWindowIDs.formIntersection(accounts.map(\.id))
    }

    /// Refuses a change while the keychain is not listed, and a name an account has already.
    func checkCanAdd(named name: String) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        if accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw StoreError.duplicateName(name)
        }
    }

    /// Deletes the account's keychain item, and with it its secret; a Vault account's entry is
    /// deleted, and its key stays in Vault.
    func remove(_ account: Account) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        if vaultProfile(of: account) != nil {
            vaultRecords.removeAll { $0.id == account.id }
            saveVaultRecords()
            vaultKeys[account.id] = nil
            vaultSecrets[account.id] = nil
            vaultCodes[account.id] = nil
        } else if account.kind == .secret {
            try Keychain.deleteSecret(account.id)
        } else {
            try Keychain.delete(account.id)
        }
        accounts.removeAll { $0.id == account.id }
        saveOrder()
        openWindowIDs.remove(account.id)
        if menuBarAccountID == account.id {
            menuBarAccountID = nil
        }
        updateSecrets()
    }

    /// Shows the account's code beside the menu bar icon, or stops showing it.
    func setShownInMenuBar(_ account: Account, _ shown: Bool) {
        if shown, account.kind == .otp {
            menuBarAccountID = account.id
        } else if menuBarAccountID == account.id {
            menuBarAccountID = nil
        }
    }

    /// Records that the account's code window was opened or closed.
    func setWindowOpen(_ id: UUID, _ open: Bool) {
        if open {
            openWindowIDs.insert(id)
        } else {
            openWindowIDs.remove(id)
        }
        updateSecrets()
    }

    /// The current code of a shown account, or nil when its secret is not held, or its code is not
    /// yet fetched from Vault.
    func code(of account: Account) -> String? {
        if vaultKeys[account.id] != nil {
            return vaultCodes[account.id].flatMap { $0.counter == counter(of: account, at: now) ? $0.code : nil }
        }
        return secrets[account.id].map { account.code(secret: $0, at: now) }
    }

    private func counter(of account: Account, at date: Date) -> Int {
        Int(date.timeIntervalSince1970) / account.period
    }

    /// The text of a secret account: read from its keychain item, or from its field in Vault.
    private func secretValue(of account: Account) async throws -> String {
        guard !brokenRecords.contains(account.id) else {
            throw StoreError.referenceMissing
        }
        guard let vaultSecret = vaultSecrets[account.id] else {
            return try Keychain.secretValue(of: account.id)
        }
        guard let session = vault(for: vaultSecret.profile) else {
            throw StoreError.profileRemoved
        }
        let reference = vaultSecret.reference
        return try await session.authorized { try await $0.readSecret(reference) }
    }

    /// Sets whether showing or copying a secret account's secret asks the user to authenticate.
    func setRequiresAuthentication(_ account: Account, _ required: Bool) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        if let index = vaultRecords.firstIndex(where: { $0.id == account.id }) {
            vaultRecords[index].authenticate = required
            saveVaultRecords()
        } else {
            try Keychain.setSecretAuthentication(account.id, required: required)
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].requiresAuthentication = required
        }
    }

    /// Asks the user to authenticate, with Touch ID, Apple Watch or the password, before a secret is
    /// shown or copied; false when the user cancels, an error otherwise.
    private func authenticated(for reason: String) async throws -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        }
    }

    /// The text of a secret account, for the user to look at, after the user authenticates when the
    /// account asks for it; nil when the user cancels. Nothing is kept of it.
    func revealSecret(of account: Account) async throws -> String? {
        if account.requiresAuthentication, try await !authenticated(for: "show the secret \(account.name)") {
            return nil
        }
        return try await secretValue(of: account)
    }

    /// Puts the text of a secret account in the clipboard, after the user authenticates when the
    /// account asks for it, marked
    /// concealed, and empties the clipboard after 30 seconds, or when the app quits, if it still holds
    /// that copy. Nothing is copied when the user cancels.
    func copySecret(of account: Account) async throws {
        if account.requiresAuthentication, try await !authenticated(for: "copy the secret \(account.name)") {
            return
        }
        let value = try await secretValue(of: account)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copiedSecret = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(30))
            clearCopiedSecret()
        }
    }

    /// Empties the clipboard if it still holds the secret copied last.
    private func clearCopiedSecret() {
        let pasteboard = NSPasteboard.general
        if let copiedSecret, pasteboard.changeCount == copiedSecret {
            pasteboard.clearContents()
        }
        copiedSecret = nil
    }

    /// Puts the account's current code in the clipboard: a code computed from the secret, which
    /// is read and not kept, or one fetched from Vault.
    func copyCode(of account: Account) async throws {
        let code: String
        if let vaultKey = vaultKeys[account.id] {
            guard let session = vault(for: vaultKey.profile) else {
                throw StoreError.profileRemoved
            }
            let key = vaultKey.key
            code = try await session.authorized { try await $0.code(key: key) }
        } else {
            let secret = try secrets[account.id] ?? Keychain.secret(of: account.id)
            code = account.code(secret: secret, at: Date())
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    /// Fetches the codes of the shown Vault accounts that have none for the present period. A
    /// failed fetch is not repeated within its period.
    private func refreshVaultCodes() {
        for account in accounts where shownIDs.contains(account.id) {
            guard let vaultKey = vaultKeys[account.id] else {
                continue
            }
            guard let session = vault(for: vaultKey.profile) else {
                continue
            }
            let key = vaultKey.key
            let counter = counter(of: account, at: now)
            guard vaultCodes[account.id]?.counter != counter, vaultFailures[account.id] != counter,
                  vaultFetching.insert(account.id).inserted else {
                continue
            }
            let id = account.id
            Task {
                defer {
                    vaultFetching.remove(id)
                }
                do {
                    let code = try await session.authorized { try await $0.code(key: key) }
                    vaultCodes[id] = VaultCode(code: code, counter: counter)
                } catch {
                    // The session records the problem.
                    vaultFailures[id] = counter
                }
            }
        }
    }

    /// The vaults whose last call failed.
    var problems: [VaultIssue] {
        vaults.compactMap { session in
            if case let .failed(problem) = session.status {
                return VaultIssue(id: session.profile.id, session: session, problem: problem)
            }
            return nil
        }
    }

    /// Why a Vault account has no code: its vault failed, or is gone.
    func problem(of account: Account) -> VaultProblem? {
        if brokenRecords.contains(account.id) {
            return VaultProblem(kind: .other, title: "The secret's reference is missing",
                                detail: "The stored record of this account holds no reference to a KV field.",
                                suggestion: "Remove the account and add it again.")
        }
        guard let profile = vaultProfile(of: account) else {
            return nil
        }
        guard let session = vault(for: profile) else {
            return VaultProblem(kind: .other, title: "The vault of this account was removed",
                                detail: "The account takes its codes from a vault that is not set up any more.",
                                suggestion: "Remove the account, or set the vault up again.")
        }
        if case let .failed(problem) = session.status {
            return problem
        }
        return nil
    }

    /// Forgets the Vault codes and failures, so the shown accounts fetch again at once.
    func vaultConnectionChanged() {
        vaultCodes = [:]
        vaultFailures = [:]
        secretErrors = secretErrors.filter { vaultKeys[$0.key] == nil }
        refreshVaultCodes()
    }

    /// Signs in to the Vault profile, so the shown codes are fetched.
    func signInToVault(_ session: VaultSession) async throws {
        defer {
            vaultConnectionChanged()
        }
        try await session.signIn()
    }

    func signOutOfVault(_ session: VaultSession) {
        session.signOut()
        vaultConnectionChanged()
    }

    /// Registers the app as a login item or unregisters it, opening the Login Items settings
    /// when macOS asks for the user's approval.
    func setLaunchesAtLogin(_ enabled: Bool) throws {
        defer {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Reads the secrets of the accounts newly shown and drops those of the accounts no longer
    /// shown, with their read errors.
    private func updateSecrets() {
        let shown = shownIDs
        secrets = secrets.filter { shown.contains($0.key) }
        secretErrors = secretErrors.filter { shown.contains($0.key) }
        for id in shown where vaultKeys[id] == nil && secrets[id] == nil && secretErrors[id] == nil {
            do {
                secrets[id] = try Keychain.secret(of: id)
            } catch {
                secretErrors[id] = error.localizedDescription
            }
        }
        refreshVaultCodes()
    }

    /// The registered accounts whose codes are shown: in an open window or beside the menu bar icon.
    private var shownIDs: Set<UUID> {
        openWindowIDs.union(menuBarAccountID.map { [$0] } ?? []).intersection(accounts.filter { $0.kind == .otp }.map(\.id))
    }

    /// The stored records of the accounts kept in Vault; none when none are stored. Records that
    /// cannot be read are an error, so that nothing is saved over them.
    private static func readVaultRecords() throws -> [VaultRecord] {
        guard let data = UserDefaults.standard.data(forKey: "vaultProfileAccounts") else {
            return []
        }
        do {
            return try JSONDecoder().decode([VaultRecord].self, from: data)
        } catch {
            throw StoreError.recordsUnreadable(error.localizedDescription)
        }
    }

    private func saveVaultRecords() {
        UserDefaults.standard.set(try? JSONEncoder().encode(vaultRecords), forKey: "vaultProfileAccounts")
    }

    private func saveOrder() {
        UserDefaults.standard.set(accounts.map(\.id.uuidString), forKey: "accountOrder")
    }
}

extension String {
    /// The code in two groups of digits, the second one the longer for an odd count.
    var groupedCode: String {
        let split = index(startIndex, offsetBy: count / 2)
        return "\(self[..<split]) \(self[split...])"
    }
}
