import AppKit
import SwiftUI
import TOTP

/// The menu bar app holding TOTP accounts and showing their current codes.
@main
struct MacAuthenticatorApp: App {
    @State private var store: AccountStore
    private let windows: CodeWindows
    private let settings: SettingsWindow

    init() {
        // Run as a menu bar app without a Dock icon, bundled or not.
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = AccountStore()
        _store = State(initialValue: store)
        windows = CodeWindows(store: store)
        settings = SettingsWindow(store: store, windows: windows)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, windows: windows, settings: settings)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu bar icon, followed by the code of the account chosen with Show in Menu Bar.
struct MenuBarLabel: View {
    let store: AccountStore

    var body: some View {
        Image(systemName: "lock.shield")
        if let account = store.menuBarAccount, let code = store.code(of: account) {
            Text(code.groupedCode)
                .monospacedDigit()
        }
    }
}

/// The items of the menu bar menu; they read no clock, so the open menu is not redrawn.
struct MenuContent: View {
    let store: AccountStore
    let windows: CodeWindows
    let settings: SettingsWindow

    var body: some View {
        if let loadError = store.loadError {
            Text(loadError)
            Button("Retry") {
                store.reload()
            }
        } else if store.accounts.isEmpty {
            Text("No Accounts")
        } else {
            ForEach(store.accounts) { account in
                Menu(account.name) {
                    Button("Copy Code") {
                        DispatchQueue.main.async { [store] in
                            Task {
                                do {
                                    try await store.copyCode(of: account)
                                } catch {
                                    Dialogs.showError("The code was not copied", error.localizedDescription)
                                }
                            }
                        }
                    }
                    Button("Show") {
                        windows.show(account)
                    }
                    Toggle("Show in Menu Bar", isOn: Binding(
                        get: { store.menuBarAccountID == account.id },
                        set: { store.setShownInMenuBar(account, $0) }
                    ))
                }
            }
        }

        Divider()
        Button("Settings...") {
            DispatchQueue.main.async { [settings] in
                settings.show()
            }
        }
        .keyboardShortcut(",")
        Toggle("Launch at Login", isOn: Binding(
            get: { store.launchesAtLogin },
            set: { enabled in
                do {
                    try store.setLaunchesAtLogin(enabled)
                } catch {
                    Dialogs.showError("Launch at Login was not changed", error.localizedDescription)
                }
            }
        ))
        Button("About Mac Authenticator") {
            DispatchQueue.main.async {
                Dialogs.activate()
                NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Mac Authenticator"])
            }
        }
        Button("Quit Mac Authenticator") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

