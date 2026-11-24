import AppKit
import TOTP
import Vault
import Vision

/// The fields of the Vault Settings alert; the rows that do not apply to the chosen sign-in
/// method are hidden.
@MainActor
private final class VaultSettingsForm: NSObject {
    let address: NSTextField
    let namespace: NSTextField
    let totpMount: NSTextField
    let authMount: NSTextField
    let username: NSTextField
    let roleID: NSTextField
    let oidcRole: NSTextField
    let oidcPort: NSTextField
    let credential = NSSecureTextField()
    private let method = NSPopUpButton()
    private let credentialLabel = NSTextField(labelWithString: "")
    let grid: NSGridView
    /// The methods each grid row applies to, by row.
    private let applicable: [Set<AuthMethod>] = [
        [.token, .userpass, .approle, .oidc], [.token, .userpass, .approle, .oidc],
        [.token, .userpass, .approle, .oidc], [.token, .userpass, .approle, .oidc],
        [.userpass, .approle, .oidc], [.userpass], [.approle], [.oidc], [.oidc], [.token, .userpass, .approle],
    ]
    private weak var alert: NSAlert?

    private static func title(of method: AuthMethod) -> String {
        switch method {
        case .token:
            return "Token"
        case .userpass:
            return "Username and password"
        case .approle:
            return "AppRole"
        case .oidc:
            return "OIDC (browser)"
        }
    }

    init(_ configuration: VaultConfiguration?) {
        address = NSTextField(string: configuration?.address ?? "")
        address.placeholderString = "https://vault.example.com:8200"
        namespace = NSTextField(string: configuration?.namespace ?? "")
        namespace.placeholderString = "Optional, Vault Enterprise"
        totpMount = NSTextField(string: configuration?.totpMount ?? "totp")
        authMount = NSTextField(string: configuration?.authMount ?? AuthMethod.token.rawValue)
        username = NSTextField(string: configuration?.username ?? "")
        roleID = NSTextField(string: configuration?.roleID ?? "")
        oidcRole = NSTextField(string: configuration?.oidcRole ?? "")
        oidcRole.placeholderString = "Empty for the default role"
        oidcPort = NSTextField(string: String(configuration?.oidcPort ?? 8250))
        credential.placeholderString = "Empty keeps the stored one"

        let rows: [(String, NSView)] = [
            ("Vault address", address), ("Namespace", namespace), ("TOTP engine mount", totpMount),
            ("Sign-in method", method), ("Auth method mount", authMount), ("Username", username),
            ("RoleID", roleID), ("OIDC role", oidcRole), ("Callback port", oidcPort),
        ]
        grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] }
                          + [[credentialLabel, credential]])
        grid.rowSpacing = 6
        super.init()

        method.addItems(withTitles: AuthMethod.allCases.map(Self.title(of:)))
        method.selectItem(at: AuthMethod.allCases.firstIndex(of: configuration?.authMethod ?? .token) ?? 0)
        method.target = self
        method.action = #selector(methodChanged)
        for field in [address, namespace, totpMount, authMount, username, roleID, oidcRole, oidcPort, credential] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        update()
    }

    private var selectedMethod: AuthMethod {
        AuthMethod.allCases[max(method.indexOfSelectedItem, 0)]
    }

    /// Shows the rows of the chosen method, and sizes the alert to them.
    private func update() {
        let selected = selectedMethod
        for (index, methods) in applicable.enumerated() {
            grid.row(at: index).isHidden = !methods.contains(selected)
        }
        switch selected {
        case .userpass:
            credentialLabel.stringValue = "Password"
        case .approle:
            credentialLabel.stringValue = "SecretID"
        default:
            credentialLabel.stringValue = "Token"
        }
        grid.setFrameSize(grid.fittingSize)
        alert?.layout()
    }

    @objc private func methodChanged() {
        if authMount.stringValue.isEmpty || AuthMethod(rawValue: authMount.stringValue) != nil {
            authMount.stringValue = selectedMethod.rawValue
        }
        update()
    }

    func attach(to alert: NSAlert) {
        self.alert = alert
        update()
    }

    /// The settings in the fields, or why they cannot be used.
    func configuration() throws -> VaultConfiguration {
        func text(_ field: NSTextField) -> String? {
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let address = text(address) else {
            throw SessionError.missingSetting("Vault address")
        }
        let selected = selectedMethod
        guard let port = Int(oidcPort.stringValue), (1 ... 65535).contains(port) else {
            throw SessionError.invalidSetting("Callback port")
        }
        if selected == .userpass, text(username) == nil {
            throw SessionError.missingSetting("Username")
        }
        if selected == .approle, text(roleID) == nil {
            throw SessionError.missingSetting("RoleID")
        }
        return VaultConfiguration(address: address, namespace: text(namespace), totpMount: text(totpMount) ?? "totp",
                                  authMethod: selected, authMount: text(authMount), username: text(username),
                                  roleID: text(roleID), oidcRole: text(oidcRole), oidcPort: port)
    }
}

/// The alerts of the menu: adding, adding from a QR code, removing, Vault, and errors.
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

    /// Asks for the Vault settings until they are saved or Cancel is chosen; saving signs in at
    /// once, except for OIDC, which is signed in from the menu.
    static func vaultSettings(for store: AccountStore) {
        let form = VaultSettingsForm(store.vault.configuration)
        var information = "A token, password or SecretID is kept in your login keychain. OIDC keeps nothing: the browser signs you in."
        while true {
            let alert = NSAlert()
            alert.messageText = "Vault Settings"
            alert.informativeText = information
            alert.accessoryView = form.grid
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            form.attach(to: alert)
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            do {
                let configuration = try form.configuration()
                try store.vault.configure(configuration, credential: form.credential.stringValue)
                store.vaultConnectionChanged()
                if configuration.authMethod != .oidc {
                    Task {
                        do {
                            try await store.signInToVault()
                        } catch {
                            showError("Vault sign-in failed", error.localizedDescription)
                        }
                    }
                }
                return
            } catch {
                information = error.localizedDescription
            }
        }
    }

    /// Asks for one of the TOTP engine's keys and a name until an account is added or Cancel is
    /// chosen. The keys the policy lets the app list are offered; any name can be typed.
    static func addVaultKey(to store: AccountStore) async {
        var information = "Pick a key of the TOTP engine, or type its name."
        let keyBox = NSComboBox()
        do {
            keyBox.addItems(withObjectValues: try await store.vault.authorized { try await $0.listKeys() })
        } catch let error as VaultError where error.isDenied {
            information = "Vault does not let this app list the keys; type the key's name."
        } catch {
            showError("The keys were not listed", error.localizedDescription)
            return
        }
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Key"), keyBox,
            NSTextField(labelWithString: "Name"), nameField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        for field in [keyBox, nameField] {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        stack.setFrameSize(stack.fittingSize)

        while true {
            let alert = NSAlert()
            alert.messageText = "Add Vault Key"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = keyBox
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let key = keyBox.stringValue.trimmingCharacters(in: .whitespaces)
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            do {
                guard !key.isEmpty else {
                    throw SessionError.missingSetting("Key")
                }
                let info = try await store.vault.authorized { try await $0.readKey(key) }
                try store.addVaultAccount(info.account(name: name.isEmpty ? info.suggestedName : name), key: key)
                return
            } catch {
                information = error.localizedDescription
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

    /// Adds the Vault key to the app as an account; an empty name is the key's suggested name.
    private static func addVaultAccount(of key: String, named name: String, to store: AccountStore) async throws {
        let info = try await store.vault.authorized { try await $0.readKey(key) }
        try store.addVaultAccount(info.account(name: name.isEmpty ? info.suggestedName : name), key: key)
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
            alert.messageText = "Vault Key Generated"
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

    /// Asks for the parameters of a key until Vault generates it or Cancel is chosen, shows its QR
    /// code, and adds it to the app.
    static func generateVaultKey(to store: AccountStore) async {
        let keyField = NSTextField()
        keyField.placeholderString = "Name of the key in Vault"
        let issuerField = NSTextField()
        issuerField.placeholderString = "The organisation the key is for"
        let accountField = NSTextField()
        accountField.placeholderString = "For example your e-mail address"
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = fieldStack([("Key", keyField), ("Issuer", issuerField), ("Account name", accountField),
                                ("Name", nameField)])

        var information = "Vault makes the secret and shows it once, to be scanned into another authenticator."
        while true {
            let alert = NSAlert()
            alert.messageText = "Generate Vault Key"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Generate")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = keyField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            let issuer = issuerField.stringValue.trimmingCharacters(in: .whitespaces)
            let accountName = accountField.stringValue.trimmingCharacters(in: .whitespaces)
            let generated: GeneratedKey
            do {
                for (value, label) in [(key, "Key"), (issuer, "Issuer"), (accountName, "Account name")] where value.isEmpty {
                    throw SessionError.missingSetting(label)
                }
                generated = try await store.vault.authorized {
                    try await $0.generateKey(key, issuer: issuer, accountName: accountName)
                }
            } catch {
                information = error.localizedDescription
                continue
            }

            // The key exists now; a failure to add it must not lead to generating it again.
            showGeneratedKey(generated)
            do {
                try await addVaultAccount(of: key, named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                          to: store)
            } catch {
                showError("The key was generated but not added", error.localizedDescription)
            }
            return
        }
    }

    /// Asks for a key name and a base32 secret or otpauth URI until Vault stores the key or Cancel
    /// is chosen, and adds it to the app.
    static func importVaultKey(to store: AccountStore) async {
        let keyField = NSTextField()
        keyField.placeholderString = "Name of the key in Vault"
        let secretField = NSSecureTextField()
        secretField.placeholderString = "Base32 secret or otpauth://totp/... URI"
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = fieldStack([("Key", keyField), ("Secret or otpauth URI", secretField), ("Name", nameField)])

        var information = "Vault supports SHA1, SHA256 and SHA512 keys of 6 or 8 digits."
        while true {
            let alert = NSAlert()
            alert.messageText = "Import Vault Key"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = keyField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            do {
                guard !key.isEmpty else {
                    throw SessionError.missingSetting("Key")
                }
                let input = secretField.stringValue
                try await store.vault.authorized { try await $0.importKey(key, input: input) }
            } catch {
                information = error.localizedDescription
                continue
            }

            // The key is stored now; a failure to add it must not lead to importing it again.
            do {
                try await addVaultAccount(of: key, named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                          to: store)
            } catch {
                showError("The key was imported but not added", error.localizedDescription)
            }
            return
        }
    }

    /// Asks before deleting the account and its secret.
    static func removeAccount(_ account: Account, from store: AccountStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = store.vaultKeys[account.id] == nil
            ? "Its secret is deleted from the keychain; the account can only be added again with the secret."
            : "The account is removed from this app; its key stays in Vault."
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
