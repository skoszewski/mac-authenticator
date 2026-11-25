import AppKit
import TOTP
import Vault
import Vision

/// The alerts of the Settings window and the menu: adding, adding from a QR code, removing, Vault keys, and errors.
@MainActor
enum Dialogs {
    /// Brings the app to the front, so its alert takes the keyboard.
    static func activate() {
        NSApp.activate()
    }

    static func showError(_ message: String, _ information: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        activate()
        alert.runModal()
    }

    /// Shows an error as its problem: what is wrong, what happened and what to do.
    static func showProblem(_ message: String, _ error: Error) {
        let problem = VaultProblem(error)
        showError(message, "\(problem.title)\n\(problem.detail)\n\n\(problem.suggestion)")
    }

    /// Asks for a name and a secret or otpauth URI until an account is added or Cancel is chosen.
    static func addAccount(to store: AccountStore, name: String = "", input: String = "") {
        let nameField = NSTextField(string: name)
        nameField.placeholderString = "Name, or empty to take it from the URI"
        let secretField = NSSecureTextField(string: input)
        secretField.placeholderString = "Base32 secret or otpauth://totp/... URI"
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Name"), nameField,
            NSTextField(labelWithString: "Secret or otpauth URI"), secretField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        for field in [nameField, secretField] {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        stack.setFrameSize(stack.fittingSize)

        var information = "The secret is kept in your login keychain."
        while true {
            let alert = NSAlert()
            alert.messageText = "Add Account"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = nameField.stringValue.isEmpty && secretField.stringValue.isEmpty
                ? nameField : secretField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            do {
                try store.add(Account.parse(name: nameField.stringValue, input: secretField.stringValue))
                return
            } catch {
                information = error.localizedDescription
            }
        }
    }

    /// Reads an otpauth URI from a QR code in the clipboard's image and asks to add it.
    static func addAccountFromClipboard(to store: AccountStore) {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showError("The clipboard holds no image",
                      "Copy an image of the QR code first, for example with Control-Shift-Command-4.")
            return
        }
        Task {
            var request = DetectBarcodesRequest()
            request.symbologies = [.qr]
            let payloads: [String]
            do {
                payloads = try await request.perform(on: cgImage, orientation: nil).compactMap(\.payloadString)
            } catch {
                showError("The QR code could not be read", error.localizedDescription)
                return
            }
            guard !payloads.isEmpty else {
                showError("No QR code was found", "The image in the clipboard holds no QR code that could be read.")
                return
            }
            guard let uri = payloads.first(where: { $0.lowercased().hasPrefix("otpauth://") }) else {
                showError("The QR code holds no otpauth URI",
                          "Only otpauth://totp/ codes can be added; exports of other apps, such as otpauth-migration://, cannot.")
                return
            }
            addAccount(to: store, input: uri)
        }
    }

    /// Asks for a vault, one of the keys of its TOTP engine, and an account name until an account is
    /// added or Cancel is chosen. The keys the policy lets the app list are offered; any name can be
    /// typed.
    static func addFromVault(to store: AccountStore) async {
        let sessions = store.vaults
        guard !sessions.isEmpty else {
            showError("No vault is set up", "Accounts can be taken from a vault once one is set up.")
            return
        }
        var keys: [UUID: [String]] = [:]
        var notes: [String] = []
        for session in sessions {
            do {
                keys[session.profile.id] = try await session.authorized { try await $0.listKeys() }
            } catch {
                keys[session.profile.id] = []
                notes.append("\(session.profile.name): \(VaultProblem(error).title).")
            }
        }
        let picker = VaultKeyPicker(sessions: sessions, keys: keys)
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = fieldStack([("Vault", picker.vaultPopUp), ("Key", picker.keyBox), ("Account name", nameField)])

        var information = "Pick a key of the vault's TOTP engine, or type its name."
        if !notes.isEmpty {
            information += " The keys could not be listed: " + notes.joined(separator: " ")
        }
        while true {
            let alert = NSAlert()
            alert.messageText = "Add from Vault"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = picker.keyBox
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let session = sessions[max(picker.vaultPopUp.indexOfSelectedItem, 0)]
            let key = picker.keyBox.stringValue.trimmingCharacters(in: .whitespaces)
            do {
                guard !key.isEmpty else {
                    throw SessionError.missingSetting("Key")
                }
                try await addVaultAccount(of: key, named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                          to: store, using: session)
                return
            } catch {
                information = VaultProblem(error).report
            }
        }
    }

    /// The labels over their fields, in a column.
    private static func fieldStack(_ rows: [(String, NSView)]) -> NSStackView {
        let stack = NSStackView(views: rows.flatMap { [NSTextField(labelWithString: $0.0), $0.1] })
        stack.orientation = .vertical
        stack.alignment = .leading
        for (_, field) in rows {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    /// Adds the account the vault key stores to the app; an empty name is the key's suggested name.
    private static func addVaultAccount(of key: String, named name: String, to store: AccountStore,
                                        using session: VaultSession) async throws {
        let info = try await session.authorized { try await $0.readKey(key) }
        try store.addVaultAccount(info.account(name: name.isEmpty ? info.suggestedName : name), key: key,
                                      profile: session.profile.id)
    }

    /// Shows the QR code and URL of a generated key until Done is chosen; Copy URL puts the URL in
    /// the clipboard.
    private static func showGeneratedKey(_ key: GeneratedKey) {
        let url = NSTextField(wrappingLabelWithString: key.url)
        url.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [url])
        stack.orientation = .vertical
        if let image = key.qrCode.flatMap({ NSImage(data: $0) }) {
            let imageView = NSImageView(image: image)
            imageView.widthAnchor.constraint(equalToConstant: 200).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 200).isActive = true
            stack.insertArrangedSubview(imageView, at: 0)
        }
        url.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.setFrameSize(stack.fittingSize)

        while true {
            let alert = NSAlert()
            alert.messageText = "Account Generated"
            alert.informativeText = "Scan the QR code with another authenticator now, or copy the URL. Vault does not show the secret again."
            alert.accessoryView = stack
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Copy URL")
            activate()
            guard alert.runModal() == .alertSecondButtonReturn else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key.url, forType: .string)
        }
    }

    /// The pop-up of the vaults to choose from, or nil, after telling so, when none is set up.
    private static func vaultPopUp(of store: AccountStore) -> NSPopUpButton? {
        guard !store.vaults.isEmpty else {
            showError("No vault is set up", "Accounts can be taken from a vault once one is set up.")
            return nil
        }
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: store.vaults.map(\.profile.name))
        return popUp
    }

    /// Asks for the parameters of an account until the vault generates it in a key or Cancel is chosen,
    /// shows its QR code, and adds the account to the app.
    static func generateAccount(to store: AccountStore) async {
        guard let vaultPopUp = vaultPopUp(of: store) else {
            return
        }
        let keyField = NSTextField()
        keyField.placeholderString = "Name of the key in the vault"
        let issuerField = NSTextField()
        issuerField.placeholderString = "The organisation the key is for"
        let accountField = NSTextField()
        accountField.placeholderString = "For example your e-mail address"
        let stack = fieldStack([("Vault", vaultPopUp), ("Vault key", keyField), ("Issuer", issuerField), ("Account name", accountField)])

        var information = "The vault makes the secret, keeps it in the key, and shows it once, to be scanned into another authenticator."
        while true {
            let alert = NSAlert()
            alert.messageText = "Generate Account in Vault"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Generate")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = keyField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let session = store.vaults[max(vaultPopUp.indexOfSelectedItem, 0)]
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            let issuer = issuerField.stringValue.trimmingCharacters(in: .whitespaces)
            let accountName = accountField.stringValue.trimmingCharacters(in: .whitespaces)
            let generated: GeneratedKey
            do {
                for (value, label) in [(key, "Vault key"), (issuer, "Issuer"), (accountName, "Account name")] where value.isEmpty {
                    throw SessionError.missingSetting(label)
                }
                generated = try await session.authorized {
                    try await $0.generateKey(key, issuer: issuer, accountName: accountName)
                }
            } catch {
                information = VaultProblem(error).report
                continue
            }

            // A failure to add the account is reported, and the key is not generated again.
            showGeneratedKey(generated)
            do {
                try await addVaultAccount(of: key, named: "", to: store, using: session)
            } catch {
                showError("The account was generated in the vault but not added", error.localizedDescription)
            }
            return
        }
    }

    /// Asks for a key name and a base32 secret or otpauth URI until the vault stores the account in the
    /// key or Cancel is chosen, and adds the account to the app.
    static func importAccount(to store: AccountStore) async {
        guard let vaultPopUp = vaultPopUp(of: store) else {
            return
        }
        let keyField = NSTextField()
        keyField.placeholderString = "Name of the key in the vault"
        let secretField = NSSecureTextField()
        secretField.placeholderString = "Base32 secret or otpauth://totp/... URI"
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = fieldStack([("Vault", vaultPopUp), ("Vault key", keyField), ("Secret or otpauth URI", secretField), ("Account name", nameField)])

        var information = "The vault keeps the secret in the key; it supports SHA1, SHA256 and SHA512 with 6 or 8 digits."
        while true {
            let alert = NSAlert()
            alert.messageText = "Import Account into Vault"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = keyField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let session = store.vaults[max(vaultPopUp.indexOfSelectedItem, 0)]
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            do {
                guard !key.isEmpty else {
                    throw SessionError.missingSetting("Vault key")
                }
                let input = secretField.stringValue
                try await session.authorized { try await $0.importKey(key, input: input) }
            } catch {
                information = VaultProblem(error).report
                continue
            }

            // A failure to add the account is reported, and the key is not imported again.
            do {
                try await addVaultAccount(of: key, named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                          to: store, using: session)
            } catch {
                showError("The account was imported into the vault but not added", error.localizedDescription)
            }
            return
        }
    }

    /// Asks before deleting the vault, its credential and its accounts.
    static func removeVaultProfile(_ session: VaultSession, from store: AccountStore) {
        let count = store.accounts(of: session.profile.id).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the vault \(session.profile.name)?"
        alert.informativeText = "Its credential is deleted from the keychain, and so are its \(count) accounts from this app; their keys stay in the vault."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try store.removeVaultProfile(session)
        } catch {
            showError("\(session.profile.name) was not removed", error.localizedDescription)
        }
    }

    /// Asks before deleting the account and its secret.
    static func removeAccount(_ account: Account, from store: AccountStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = store.vaultKeys[account.id] == nil
            ? "Its secret is deleted from the keychain; the account can only be added again with the secret."
            : "The account is removed from this app; its key stays in the vault."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try store.remove(account)
        } catch {
            showError("\(account.name) was not removed", error.localizedDescription)
        }
    }
}

/// The vault pop-up and key combo box of the Add from Vault alert; choosing another vault offers
/// the keys listed for it.
@MainActor
private final class VaultKeyPicker: NSObject {
    let vaultPopUp = NSPopUpButton()
    let keyBox = NSComboBox()
    private let sessions: [VaultSession]
    private let keys: [UUID: [String]]

    init(sessions: [VaultSession], keys: [UUID: [String]]) {
        self.sessions = sessions
        self.keys = keys
        super.init()
        vaultPopUp.addItems(withTitles: sessions.map(\.profile.name))
        vaultPopUp.target = self
        vaultPopUp.action = #selector(vaultChanged)
        vaultChanged()
    }

    @objc private func vaultChanged() {
        keyBox.removeAllItems()
        keyBox.stringValue = ""
        keyBox.addItems(withObjectValues: keys[sessions[max(vaultPopUp.indexOfSelectedItem, 0)].profile.id] ?? [])
    }
}
