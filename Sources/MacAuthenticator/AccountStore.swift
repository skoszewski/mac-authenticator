import AppKit
import Observation
import ServiceManagement
import TOTP

/// Why the account list was not changed.
enum StoreError: LocalizedError {
    case duplicateName(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case let .duplicateName(name):
            return "An account named \(name) exists already."
        case .notLoaded:
            return "The accounts were not read from the keychain, so they are not changed."
        }
    }
}

/// The registered accounts, the secrets of those whose codes are shown, and the clock the codes
/// are shown for.
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
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
        reload()
        let start = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970))
        let timer = Timer(fire: start, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Lists the accounts from the keychain again, in the stored menu order; accounts missing
    /// from the order follow by the creation of their items.
    func reload() {
        do {
            let order = UserDefaults.standard.stringArray(forKey: "accountOrder") ?? []
            let listed = try Keychain.accounts()
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
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        if accounts.contains(where: { $0.name.caseInsensitiveCompare(new.account.name) == .orderedSame }) {
            throw StoreError.duplicateName(new.account.name)
        }
        try Keychain.add(new)
        accounts.append(new.account)
        saveOrder()
    }

    /// Deletes the account's keychain item, and with it its secret.
    func remove(_ account: Account) throws {
        guard loadError == nil else {
            throw StoreError.notLoaded
        }
        try Keychain.delete(account.id)
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

    /// The current code of a shown account, or nil when its secret is not held.
    func code(of account: Account) -> String? {
        secrets[account.id].map { account.code(secret: $0, at: now) }
    }

    /// Reads the account's secret and puts its current code in the clipboard, keeping no secret.
    func copyCode(of account: Account) throws {
        let secret = try secrets[account.id] ?? Keychain.secret(of: account.id)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(account.code(secret: secret, at: Date()), forType: .string)
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
        let ids = Set(accounts.map(\.id))
        let shown = openWindowIDs.union(menuBarAccountID.map { [$0] } ?? []).intersection(ids)
        secrets = secrets.filter { shown.contains($0.key) }
        secretErrors = secretErrors.filter { shown.contains($0.key) }
        for id in shown where secrets[id] == nil && secretErrors[id] == nil {
            do {
                secrets[id] = try Keychain.secret(of: id)
            } catch {
                secretErrors[id] = error.localizedDescription
            }
        }
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
