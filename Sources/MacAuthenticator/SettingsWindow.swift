import AppKit
import Observation
import SwiftUI

/// What the Settings window shows: its tab, and a vault to select on the Vaults tab.
@MainActor
@Observable
final class SettingsRouter {
    enum Tab {
        case accounts
        case vaults
    }

    var tab = Tab.accounts
    var vault: UUID?
}

/// The Settings window, made on the first call and kept: an AppKit window hosting SwiftUI. The app
/// is a regular app, with a Dock icon and a place in Cmd-Tab, while the window is open.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let store: AccountStore
    private let windows: CodeWindows
    private let router = SettingsRouter()
    private var window: NSWindow?

    init(store: AccountStore, windows: CodeWindows) {
        self.store = store
        self.windows = windows
    }

    /// Brings the window to the front and gives it the keyboard; a vault is selected on the Vaults tab.
    func show(vault: UUID? = nil) {
        if let vault {
            router.tab = .vaults
            router.vault = vault
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Mac Authenticator Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, windows: windows, router: router))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        Dialogs.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Returns the app to the menu bar alone.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
