import AppKit
import TOTP
import Vision

/// The alerts of the menu: adding, adding from a QR code, removing, and errors.
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

    /// Asks before deleting the account and its secret.
    static func removeAccount(_ account: Account, from store: AccountStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = "Its secret is deleted from the keychain; the account can only be added again with the secret."
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
