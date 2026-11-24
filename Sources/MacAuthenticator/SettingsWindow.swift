import AppKit
import SwiftUI

/// The Settings window, made on the first call and kept: an AppKit window hosting SwiftUI.
@MainActor
final class SettingsWindow {
    private let store: AccountStore
    private let windows: CodeWindows
    private var window: NSWindow?

    init(store: AccountStore, windows: CodeWindows) {
        self.store = store
        self.windows = windows
    }

    /// Brings the window to the front and gives it the keyboard.
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Mac Authenticator Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, windows: windows))
            window.center()
            self.window = window
        }
        Dialogs.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
