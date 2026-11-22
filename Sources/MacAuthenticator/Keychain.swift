import Foundation
import Security
import TOTP

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
}
