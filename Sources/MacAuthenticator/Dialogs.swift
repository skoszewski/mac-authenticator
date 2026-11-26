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

    /// Asks for a vault, one of the keys of its TOTP engine, and an account name, and adds the account.
    /// The keys the policy lets the app list are offered, after the alert opens; any name can be typed.
    static func addFromVault(to store: AccountStore) async {
        let sessions = store.vaults
        guard !sessions.isEmpty else {
            showError("No vault is set up", "Accounts can be taken from a vault once one is set up.")
            return
        }
        let picker = VaultKeyPicker(sessions: sessions)
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to take it from the key"
        let stack = fieldStack([("Vault", picker.vaultPopUp), ("Key", picker.keyBox), ("Account name", nameField)])

        let alert = BusyAlert(title: "Add from Vault", text: "Pick a key of the vault's TOTP engine, or type its name.",
                              okTitle: "Add", accessory: stack, firstResponder: picker.keyBox) { busy in
            let key = picker.keyBox.stringValue.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw SessionError.missingSetting("Key")
            }
            busy.progress("Reading the key from the vault")
            try await addVaultAccount(of: key, named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                      to: store, using: picker.session)
            return true
        }
        _ = alert.run()
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
        let info = try await session.authorized("Reading the key") { try await $0.readKey(key) }
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

    /// Asks for the parameters of an account, has the vault generate it in a key, shows its QR code, and
    /// adds the account to the app.
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

        var generated: GeneratedKey?
        var generatedIn: VaultSession?
        let alert = BusyAlert(title: "Generate Account in Vault",
                              text: "The vault makes the secret, keeps it in the key, and shows it once, to be scanned into another authenticator.",
                              okTitle: "Generate", accessory: stack, firstResponder: keyField) { busy in
            let session = store.vaults[max(vaultPopUp.indexOfSelectedItem, 0)]
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            let issuer = issuerField.stringValue.trimmingCharacters(in: .whitespaces)
            let accountName = accountField.stringValue.trimmingCharacters(in: .whitespaces)
            for (value, label) in [(key, "Vault key"), (issuer, "Issuer"), (accountName, "Account name")] where value.isEmpty {
                throw SessionError.missingSetting(label)
            }
            try store.checkCanAdd(named: "\(issuer): \(accountName)")
            busy.progress("Generating the key in the vault")
            generated = try await session.authorized("Generating the key") {
                try await $0.generateKey(key, issuer: issuer, accountName: accountName)
            }
            generatedIn = session
            return true
        }
        guard alert.run(), let generated, let session = generatedIn else {
            return
        }

        // A failure to add the account is reported, and the key is not generated again.
        showGeneratedKey(generated)
        do {
            try await addVaultAccount(of: keyField.stringValue.trimmingCharacters(in: .whitespaces), named: "", to: store,
                                      using: session)
        } catch is CancellationError {
            showError("The account was generated in the vault but not added", "The request was cancelled.")
        } catch {
            showError("The account was generated in the vault but not added", error.localizedDescription)
        }
    }

    /// Asks for a key name and a base32 secret or otpauth URI, has the vault store the account in the
    /// key, and adds the account to the app.
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

        var importedIn: VaultSession?
        let alert = BusyAlert(title: "Import Account into Vault",
                              text: "The vault keeps the secret in the key; it supports SHA1, SHA256 and SHA512 with 6 or 8 digits.",
                              okTitle: "Import", accessory: stack, firstResponder: keyField) { busy in
            let session = store.vaults[max(vaultPopUp.indexOfSelectedItem, 0)]
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw SessionError.missingSetting("Vault key")
            }
            let input = secretField.stringValue
            let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            try store.checkCanAdd(named: typed.isEmpty ? try Account.parse(name: key, input: input).account.name : typed)
            busy.progress("Importing the key into the vault")
            try await session.authorized("Importing the key") { try await $0.importKey(key, input: input) }
            importedIn = session
            return true
        }
        guard alert.run(), let session = importedIn else {
            return
        }

        // A failure to add the account is reported, and the key is not imported again.
        do {
            try await addVaultAccount(of: keyField.stringValue.trimmingCharacters(in: .whitespaces),
                                      named: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                      to: store, using: session)
        } catch is CancellationError {
            showError("The account was imported into the vault but not added", "The request was cancelled.")
        } catch {
            showError("The account was imported into the vault but not added", error.localizedDescription)
        }
    }

    /// Asks for a name and a secret until a secret account is added or Cancel is chosen.
    static func addSecret(to store: AccountStore) {
        let nameField = NSTextField()
        nameField.placeholderString = "Name of the account"
        let secretField = NSSecureTextField()
        secretField.placeholderString = "The password or key to keep"
        let authenticate = NSButton(checkboxWithTitle: "Ask to authenticate before it is shown or copied", target: nil, action: nil)
        authenticate.state = .on
        let stack = fieldStack([("Name", nameField), ("Secret", secretField), ("Authentication", authenticate)])

        var information = "The secret is kept in your login keychain."
        while true {
            let alert = NSAlert()
            alert.messageText = "Add Secret"
            alert.informativeText = information
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = nameField.stringValue.isEmpty ? nameField : secretField
            activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            do {
                try store.addSecret(name: nameField.stringValue, value: secretField.stringValue,
                                    requiresAuthentication: authenticate.state == .on)
                return
            } catch {
                information = error.localizedDescription
            }
        }
    }

    /// Asks for the vault, the KV version, the mount, the secret and the field, and adds a secret account
    /// reading that field. When writing, it also asks for the value, which is set in the field first; the
    /// vault's other fields of the secret are kept, and a field that holds a value is replaced only after
    /// the alert says so and the button is pressed again.
    static func addVaultSecret(to store: AccountStore, writing: Bool) async {
        guard !store.vaults.isEmpty else {
            showError("No vault is set up", "Accounts can be taken from a vault once one is set up.")
            return
        }
        let picker = VaultSecretPicker(sessions: store.vaults)
        let valueField = NSSecureTextField()
        valueField.placeholderString = "The password or key to keep"
        let nameField = NSTextField()
        nameField.placeholderString = "Empty to use the secret name and the field"
        var rows: [(String, NSView)] = [
            ("Vault", picker.vaultPopUp), ("KV version", picker.versionPopUp), ("Mount", picker.mountField),
            ("Secret name", picker.nameBox), ("Field", picker.fieldField),
        ]
        if writing {
            rows.append(("Secret value", valueField))
        }
        rows.append(("Account name", nameField))
        let authenticate = NSButton(checkboxWithTitle: "Ask to authenticate before it is shown or copied", target: nil, action: nil)
        authenticate.state = .on
        rows.append(("Authentication", authenticate))
        let stack = fieldStack(rows)

        var confirmed: SecretReference?
        var addFailure: String?
        let alert = BusyAlert(
            title: writing ? "Add Secret in Vault" : "Add Secret from Vault",
            text: writing
                ? "The field is set in the vault's secret, which is created when it does not exist; its other fields are kept."
                : "Pick a secret of the mount, or type its name, and name the field to read.",
            okTitle: "Add", accessory: stack, firstResponder: picker.mountField
        ) { busy in
            let session = picker.session
            let reference = try picker.reference.validated()
            let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let accountName = typed.isEmpty ? "\(reference.name): \(reference.field)" : typed
            try store.checkCanAdd(named: accountName)
            if writing {
                let value = valueField.stringValue
                guard !value.isEmpty else {
                    throw StoreError.emptySecret
                }
                if confirmed != reference {
                    busy.progress("Checking the field in the vault")
                    do {
                        if try await session.authorized("Checking the field", { try await $0.secretFieldExists(reference) }) {
                            confirmed = reference
                            busy.ask("The field \(reference.field) of the secret \(reference.name) holds a value, which is replaced. "
                                     + "Press Replace to write it.", okTitle: "Replace")
                            return false
                        }
                    } catch let error as VaultError where error.isDenied {
                        confirmed = reference
                        busy.ask("The vault does not let this token read the field, so it cannot be told whether the field holds a "
                                 + "value. A value it holds is replaced. Press Write to write it.", okTitle: "Write")
                        return false
                    }
                }
                busy.progress("Writing the secret in the vault")
                try await session.authorized("Writing the secret") { try await $0.writeSecret(reference, value: value) }
            } else {
                busy.progress("Reading the secret from the vault")
                _ = try await session.authorized("Reading the secret") { try await $0.readSecret(reference) }
            }
            // A failure to add the account is reported, and the secret is not written again.
            do {
                try store.addVaultSecret(name: accountName, reference: reference, profile: session.profile.id,
                                         requiresAuthentication: authenticate.state == .on)
            } catch {
                addFailure = error.localizedDescription
            }
            return true
        }
        if alert.run(), let addFailure {
            showError(writing ? "The secret was written in the vault but the account was not added"
                              : "The account was not added", addFailure)
        }
    }

    /// Warns that the address or the namespace of a vault changed, and asks whether the token of its
    /// sign-in is kept: true to keep it, false to delete it, nil to cancel the change.
    static func askToKeepToken(of session: VaultSession, newConfiguration: VaultConfiguration) -> Bool? {
        func server(_ configuration: VaultConfiguration) -> String {
            let namespace = configuration.namespace.map { ", namespace \($0)" } ?? ""
            return "\(configuration.address)\(namespace)"
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The address or the namespace of \(session.profile.name) changed"
        alert.informativeText = "The token of the sign-in was obtained from \(server(session.configuration)). "
            + "Keep it for \(server(newConfiguration)), or delete it?"
        alert.addButton(withTitle: "Keep Token")
        alert.addButton(withTitle: "Delete Token")
        alert.addButton(withTitle: "Cancel")
        activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            return false
        default:
            return nil
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
        switch (store.vaultProfile(of: account) != nil, account.kind) {
        case (true, .otp):
            alert.informativeText = "The account is removed from this app; its key stays in the vault."
        case (true, .secret):
            alert.informativeText = "The account is removed from this app; its secret stays in the vault."
        case (false, .otp):
            alert.informativeText = "Its secret is deleted from the keychain; the account can only be added again with the secret."
        case (false, .secret):
            alert.informativeText = "Its secret is deleted from the keychain and cannot be recovered from this app."
        }
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

/// The vault pop-up and key combo box of the Add from Vault alert; the keys of the chosen vault are
/// listed when the alert opens and when the vault changes, and offered, and any name can be typed.
@MainActor
private final class VaultKeyPicker: NSObject {
    let vaultPopUp = NSPopUpButton()
    let keyBox = NSComboBox()
    private let sessions: [VaultSession]
    private var listing: Task<Void, Never>?

    init(sessions: [VaultSession]) {
        self.sessions = sessions
        super.init()
        vaultPopUp.addItems(withTitles: sessions.map(\.profile.name))
        vaultPopUp.target = self
        vaultPopUp.action = #selector(vaultChanged)
        vaultChanged()
    }

    var session: VaultSession {
        sessions[max(vaultPopUp.indexOfSelectedItem, 0)]
    }

    @objc private func vaultChanged() {
        listing?.cancel()
        keyBox.removeAllItems()
        keyBox.stringValue = ""
        keyBox.placeholderString = "Listing the keys..."
        let session = session
        listing = Task {
            do {
                let keys = try await session.authorized("Listing the keys") { try await $0.listKeys() }
                if !Task.isCancelled {
                    keyBox.addItems(withObjectValues: keys)
                    keyBox.placeholderString = "Name of the key"
                }
            } catch is CancellationError {
                if !Task.isCancelled {
                    keyBox.placeholderString = "Not listed: cancelled"
                }
            } catch {
                if !Task.isCancelled {
                    keyBox.placeholderString = "Not listed: \(VaultProblem(error).title)"
                }
            }
        }
    }
}

/// The fields of the Add Secret in Vault and Add Secret from Vault alerts: the vault, the KV version,
/// the mount, and the secret and field to name. The secret names of the mount are listed when the
/// vault, the version or the mount changes, and offered; any name can be typed.
@MainActor
private final class VaultSecretPicker: NSObject, NSTextFieldDelegate {
    let vaultPopUp = NSPopUpButton()
    let versionPopUp = NSPopUpButton()
    let mountField = NSTextField(string: "secret")
    let nameBox = NSComboBox()
    let fieldField = NSTextField(string: "password")
    private let sessions: [VaultSession]
    private var listing: Task<Void, Never>?

    init(sessions: [VaultSession]) {
        self.sessions = sessions
        super.init()
        vaultPopUp.addItems(withTitles: sessions.map(\.profile.name))
        versionPopUp.addItems(withTitles: ["KV v2", "KV v1"])
        for popUp in [vaultPopUp, versionPopUp] {
            popUp.target = self
            popUp.action = #selector(changed)
        }
        mountField.delegate = self
        mountField.placeholderString = "The mount of the KV engine"
        fieldField.placeholderString = "For example password"
        nameBox.placeholderString = "Name of the secret"
        changed()
    }

    var session: VaultSession {
        sessions[max(vaultPopUp.indexOfSelectedItem, 0)]
    }

    var version: KVVersion {
        versionPopUp.indexOfSelectedItem == 1 ? .v1 : .v2
    }

    var reference: SecretReference {
        SecretReference(version: version, mount: mountField.stringValue, name: nameBox.stringValue, field: fieldField.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        changed()
    }

    /// Lists the secrets of the mount again; the list of a vault, version or mount that was left is dropped.
    @objc private func changed() {
        listing?.cancel()
        let session = session
        let version = version
        let mount = mountField.stringValue
        nameBox.removeAllItems()
        guard !mount.trimmingCharacters(in: CharacterSet(charactersIn: " /")).isEmpty else {
            return
        }
        nameBox.placeholderString = "Listing the secrets..."
        listing = Task {
            do {
                let names = try await session.authorized("Listing the secrets") {
                    try await $0.listSecrets(mount: mount, version: version)
                }
                if !Task.isCancelled {
                    nameBox.addItems(withObjectValues: names)
                    nameBox.placeholderString = "Name of the secret"
                }
            } catch is CancellationError {
                if !Task.isCancelled {
                    nameBox.placeholderString = "Not listed: cancelled"
                }
            } catch {
                if !Task.isCancelled {
                    nameBox.placeholderString = "Not listed: \(VaultProblem(error).title)"
                }
            }
        }
    }
}

/// An alert whose first button runs a call to the vault while the alert stays open: the button is
/// disabled, the second button becomes Cancel Request, and a spinner with a line says what is done. The
/// alert closes when the action is done, shows an error in its text and stays open when the action
/// fails, and the second button closes it when nothing runs.
@MainActor
private final class BusyAlert: NSObject {
    private let alert = NSAlert()
    private let accessory: NSStackView
    private let progressRow: NSStackView
    private let progressLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let idleText: String
    private var idleTitle: String
    private let action: (BusyAlert) async throws -> Bool
    private var task: Task<Void, Never>?

    /// The action returns true when it is done, which closes the alert, and false to leave it open.
    init(title: String, text: String, okTitle: String, accessory: NSStackView, firstResponder: NSView?,
         action: @escaping (BusyAlert) async throws -> Bool) {
        self.accessory = accessory
        self.idleText = text
        self.idleTitle = okTitle
        self.action = action
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        progressRow = NSStackView(views: [spinner, progressLabel])
        progressRow.orientation = .horizontal
        progressRow.isHidden = true
        super.init()
        accessory.addArrangedSubview(progressRow)
        alert.messageText = title
        alert.informativeText = text
        alert.accessoryView = accessory
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(okPressed)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(cancelPressed)
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = firstResponder
        relayout()
    }

    /// Shows the alert; true when the action was done.
    func run() -> Bool {
        Dialogs.activate()
        let done = alert.runModal() == .alertFirstButtonReturn
        alert.window.orderOut(nil)
        return done
    }

    /// Says what the action is doing now.
    func progress(_ text: String) {
        progressLabel.stringValue = text + "..."
    }

    /// Leaves the alert open with a question that the first button, retitled, answers.
    func ask(_ text: String, okTitle: String) {
        alert.informativeText = text
        idleTitle = okTitle
    }

    private func setBusy(_ busy: Bool) {
        alert.buttons[0].isEnabled = !busy
        alert.buttons[0].title = idleTitle
        alert.buttons[1].title = busy ? "Cancel Request" : "Cancel"
        progressRow.isHidden = !busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        relayout()
    }

    private func relayout() {
        accessory.setFrameSize(accessory.fittingSize)
        alert.layout()
    }

    @objc private func okPressed() {
        guard task == nil else {
            return
        }
        progress("Contacting the vault")
        setBusy(true)
        task = Task {
            do {
                let done = try await action(self)
                task = nil
                if done {
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                } else {
                    setBusy(false)
                }
            } catch is CancellationError {
                task = nil
                alert.informativeText = idleText
                setBusy(false)
            } catch {
                task = nil
                alert.informativeText = VaultProblem(error).report
                setBusy(false)
            }
        }
    }

    @objc private func cancelPressed() {
        if let task {
            task.cancel()
        } else {
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
    }
}
