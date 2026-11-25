import Foundation
import Security
import TOTP
import Vault

/// The accounts as generic password items of the login keychain, one per account: the item's
/// data is the base32 secret and its attributes hold the rest of the account.
enum Keychain {
    static let service = "pl.waw.koszewscy.MacAuthenticator"
    static let itemDescription = "Mac Authenticator TOTP secret"

    /// A keychain call that did not succeed, with the system's description of its status.
    struct Failure: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The keychain could not \(operation): \(message)"
        }
    }

    /// An account read from the attributes of its item, with the item's creation date.
    struct Listed {
        let account: Account
        let created: Date
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// The accounts of all items, read from their attributes alone; an item whose attributes
    /// cannot be read is left out.
    static func accounts() throws -> [Listed] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw Failure(operation: "list the accounts", status: status)
        }
        return items.compactMap { item in
            guard let id = (item[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)),
                  let name = item[kSecAttrLabel as String] as? String,
                  let generic = item[kSecAttrGeneric as String] as? Data,
                  let parameters = String(data: generic, encoding: .utf8),
                  let account = try? Account(id: id, name: name, issuer: item[kSecAttrComment as String] as? String,
                                             parameters: parameters) else {
                return nil
            }
            return Listed(account: account, created: item[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
    }

    /// The base32 secret of the account's item.
    static func secret(of id: UUID) throws -> String {
        var query = query(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw Failure(operation: "read the secret", status: status)
        }
        return secret
    }

    /// Adds the account's item.
    static func add(_ new: NewAccount) throws {
        var attributes = query(new.account.id)
        attributes[kSecAttrLabel as String] = new.account.name
        attributes[kSecAttrDescription as String] = itemDescription
        attributes[kSecAttrGeneric as String] = Data(new.account.parameters.utf8)
        if let issuer = new.account.issuer {
            attributes[kSecAttrComment as String] = issuer
        }
        attributes[kSecValueData as String] = Data(new.secret.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure(operation: "add the account", status: status)
        }
    }

    /// Deletes the account's item; an item already gone is no failure.
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "remove the account", status: status)
        }
    }

    /// The secret accounts are the items of a service of their own, so a build that knows only OTP
    /// accounts does not read a secret as a TOTP secret.
    private static let secretService = service + ".secret"
    static let secretItemDescription = "Mac Authenticator secret"

    private static func secretQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// The secret accounts of all items, read from their attributes alone; an item whose
    /// attributes cannot be read is left out.
    static func secretAccounts() throws -> [Listed] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw Failure(operation: "list the secrets", status: status)
        }
        return items.compactMap { item in
            guard let id = (item[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)),
                  let name = item[kSecAttrLabel as String] as? String else {
                return nil
            }
            return Listed(account: Account(secretID: id, name: name),
                          created: item[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
    }

    /// The text of the secret account's item.
    static func secretValue(of id: UUID) throws -> String {
        var query = secretQuery(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(operation: "read the secret", status: status)
        }
        return value
    }

    /// Adds the secret account's item.
    static func addSecret(id: UUID, name: String, value: String) throws {
        var attributes = secretQuery(id)
        attributes[kSecAttrLabel as String] = name
        attributes[kSecAttrDescription as String] = secretItemDescription
        attributes[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure(operation: "add the secret", status: status)
        }
    }

    /// Deletes the secret account's item; one already gone is no failure.
    static func deleteSecret(_ id: UUID) throws {
        let status = SecItemDelete(secretQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "remove the secret", status: status)
        }
    }

    /// The Vault profiles are the items of a service of their own.
    private static let vaultService = service + ".vault"
    static let vaultItemDescription = "Mac Authenticator Vault profile"

    private static func vaultQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: account,
        ]
    }

    /// The profiles of all items, read from their attributes alone, in the order of their
    /// creation; an item whose attributes cannot be read is left out.
    static func vaultProfiles() throws -> [VaultProfile] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw Failure(operation: "list the Vault profiles", status: status)
        }
        let profiles: [(profile: VaultProfile, created: Date)] = items.compactMap { item in
            guard let id = (item[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)),
                  let name = item[kSecAttrLabel as String] as? String,
                  let generic = item[kSecAttrGeneric as String] as? Data,
                  let configuration = try? JSONDecoder().decode(VaultConfiguration.self, from: generic) else {
                return nil
            }
            return (VaultProfile(id: id, name: name, configuration: configuration),
                    item[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
        return profiles.sorted { $0.created < $1.created }.map(\.profile)
    }

    /// The Vault token, password or SecretID of the profile; nil when none is stored.
    static func vaultCredential(of id: UUID) throws -> String? {
        var query = vaultQuery(account: id.uuidString)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw Failure(operation: "read the Vault credential", status: status)
        }
        return credential.isEmpty ? nil : credential
    }

    /// Adds the profile's item; the credential is empty for OIDC.
    static func addVaultProfile(_ profile: VaultProfile, credential: String) throws {
        var attributes = vaultQuery(account: profile.id.uuidString)
        attributes[kSecAttrLabel as String] = profile.name
        attributes[kSecAttrDescription as String] = vaultItemDescription
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(profile.configuration)
        attributes[kSecValueData as String] = Data(credential.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure(operation: "add the Vault profile", status: status)
        }
    }

    /// Replaces the profile's name and settings, and its credential when one is given; OIDC
    /// profiles pass an empty credential.
    static func updateVaultProfile(_ profile: VaultProfile, credential: String?) throws {
        var attributes: [String: Any] = [
            kSecAttrLabel as String: profile.name,
            kSecAttrGeneric as String: try JSONEncoder().encode(profile.configuration),
        ]
        if let credential {
            attributes[kSecValueData as String] = Data(credential.utf8)
        }
        let status = SecItemUpdate(vaultQuery(account: profile.id.uuidString) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw Failure(operation: "update the Vault profile", status: status)
        }
    }

    /// Deletes the profile's item and its token item; ones already gone are no failure.
    static func deleteVaultProfile(_ id: UUID) throws {
        let status = SecItemDelete(vaultQuery(account: id.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "remove the Vault profile", status: status)
        }
        try deleteVaultToken(of: id)
    }

    /// The tokens of OIDC sign-ins are the items of a service of their own, one per profile, so a
    /// profile's credential is never taken for a token.
    private static let vaultTokenService = service + ".vault.token"
    static let vaultTokenItemDescription = "Mac Authenticator Vault token"

    private static func vaultTokenQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultTokenService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// The token kept for the profile; nil when none is kept.
    static func vaultToken(of id: UUID) throws -> VaultToken? {
        var query = vaultTokenQuery(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let token = try? JSONDecoder().decode(VaultToken.self, from: data) else {
            throw Failure(operation: "read the Vault token", status: status)
        }
        return token
    }

    /// Keeps the token as the profile's token item, replacing the one kept.
    static func saveVaultToken(_ token: VaultToken, of id: UUID) throws {
        let data = try JSONEncoder().encode(token)
        var attributes = vaultTokenQuery(id)
        attributes[kSecAttrDescription as String] = vaultTokenItemDescription
        attributes[kSecValueData as String] = data
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(vaultTokenQuery(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw Failure(operation: "keep the Vault token", status: status)
        }
    }

    /// Deletes the profile's token item; one already gone is no failure.
    static func deleteVaultToken(of id: UUID) throws {
        let status = SecItemDelete(vaultTokenQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "forget the Vault token", status: status)
        }
    }

    /// Deletes the credential item that belongs to no profile.
    static func deleteLegacyVaultCredential() {
        SecItemDelete(vaultQuery(account: "credential") as CFDictionary)
    }
}
