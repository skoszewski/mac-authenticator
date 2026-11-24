import AppKit
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

    var errorDescription: String? {
        switch self {
        case let .duplicateName(name):
            return "An account named \(name) exists already."
        case let .duplicateProfileName(name):
            return "A vault named \(name) exists already."
        case .missingProfileName:
            return "Give the vault a name."
        case .profileRemoved:
            return "The vault of this account was removed."
        case .notLoaded:
            return "The accounts were not read from the keychain, so they are not changed."
        }
    }
}

/// The profile and the name of the key an account whose codes Vault makes is read from.
struct VaultKey: Equatable {
    var profile: UUID
    var key: String
}

/// An account whose codes Vault makes: the account's parameters, its profile and the name of its key.
private struct VaultRecord: Codable {
    var id: UUID
    var profile: UUID
    var name: String
    var issuer: String?
    var parameters: String
    var key: String
    var added: Date
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
    /// The sessions of the Vault profiles, in the order the profiles were created.
    private(set) var vaults: [VaultSession] = []
    /// The Vault key and profile of each account whose codes Vault makes.
    private(set) var vaultKeys: [UUID: VaultKey] = [:]
    private var vaultCodes: [UUID: VaultCode] = [:]
    @ObservationIgnored private var vaultRecords: [VaultRecord] = UserDefaults.standard.data(forKey: "vaultProfileAccounts")
        .flatMap { try? JSONDecoder().decode([VaultRecord].self, from: $0) } ?? []
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
    }

    /// Lists the Vault profiles and the accounts from the keychain again, in the stored menu order;
    /// accounts missing from the order follow by the creation of their items. The session of a
    /// profile that is still there is kept, with its token.
    func reload() {
        do {
            vaults = try Keychain.vaultProfiles().map { profile in
                guard let session = vaults.first(where: { $0.profile.id == profile.id }) else {
                    return VaultSession(profile: profile)
                }
                if session.profile != profile {
                    session.update(profile)
                }
                return session
            }
            let order = UserDefaults.standard.stringArray(forKey: "accountOrder") ?? []
            let vaultListed = vaultRecords.compactMap { record in
                (try? Account(id: record.id, name: record.name, issuer: record.issuer, parameters: record.parameters))
                    .map { Keychain.Listed(account: $0, created: record.added) }
            }
            vaultKeys = Dictionary(uniqueKeysWithValues: vaultRecords.map { ($0.id, VaultKey(profile: $0.profile, key: $0.key)) })
            let listed = try Keychain.accounts() + vaultListed
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
        vaultRecords.append(VaultRecord(id: account.id, profile: profile, name: account.name, issuer: account.issuer,
                                        parameters: account.parameters, key: key, added: Date()))
        saveVaultRecords()
        vaultKeys[account.id] = VaultKey(profile: profile, key: key)
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
        reload()
        return vault(for: profile.id) ?? VaultSession(profile: profile)
    }

    /// Replaces the profile's name and settings, and its credential when one is given; an OIDC
    /// profile's credential is deleted. The session signs out.
    func updateVaultProfile(_ session: VaultSession, name: String, configuration: VaultConfiguration,
                            credential: String?) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        try checkProfileName(name, excluding: session.profile.id)
        let profile = VaultProfile(id: session.profile.id, name: name, configuration: configuration)
        try Keychain.updateVaultProfile(profile, credential: configuration.authMethod == .oidc ? "" : credential)
        session.update(profile)
        vaultConnectionChanged()
        reload()
    }

    /// The accounts whose codes the Vault profile makes.
    func accounts(of profile: UUID) -> [Account] {
        accounts.filter { vaultKeys[$0.id]?.profile == profile }
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
    private func checkCanAdd(named name: String) throws {
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
        if vaultKeys[account.id] == nil {
            try Keychain.delete(account.id)
        } else {
            vaultRecords.removeAll { $0.id == account.id }
            saveVaultRecords()
            vaultKeys[account.id] = nil
            vaultCodes[account.id] = nil
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
        if shown {
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
                if secretErrors[account.id] != StoreError.profileRemoved.localizedDescription {
                    secretErrors[account.id] = StoreError.profileRemoved.localizedDescription
                }
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
                    secretErrors[id] = nil
                } catch {
                    vaultFailures[id] = counter
                    secretErrors[id] = error.localizedDescription
                }
            }
        }
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
        openWindowIDs.union(menuBarAccountID.map { [$0] } ?? []).intersection(accounts.map(\.id))
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
