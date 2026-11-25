import AppKit
import SwiftUI
import TOTP

/// The floating windows showing one account's code each, at most one per account; the store is
/// told which are open, so it holds the secrets of those accounts alone.
@MainActor
final class CodeWindows {
    private let store: AccountStore
    private var panels: [UUID: NSPanel] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    init(store: AccountStore) {
        self.store = store
    }

    /// Brings the account's window to the front, making it on the first call.
    func show(_ account: Account) {
        if let panel = panels[account.id] {
            store.setWindowOpen(account.id, true)
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 110),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = account.name
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CodeView(store: store, accountID: account.id))
        panel.center()
        let id = account.id
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.setWindowOpen(id, false)
            }
        }
        panels[id] = panel
        store.setWindowOpen(id, true)
        panel.orderFrontRegardless()
    }

    /// Closes and forgets the windows of accounts no longer registered.
    func closeRemoved() {
        let ids = Set(store.accounts.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            if let observer = closeObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(observer)
            }
            panels[id] = nil
        }
    }
}

/// The content of a code window: the code, the time left of it, and a Copy button; or why the
/// secret could not be read. A Vault code that is not fetched yet is empty, with a dot in the
/// corner.
struct CodeView: View {
    let store: AccountStore
    let accountID: UUID

    var body: some View {
        let now = store.now
        if let account = store.accounts.first(where: { $0.id == accountID }) {
            let code = store.code(of: account)
            let problem = store.problem(of: account)
            // A Vault code not yet fetched keeps the layout of a shown code, with an empty code.
            let waiting = code == nil && store.vaultKeys[accountID] != nil && problem == nil
                && store.secretErrors[accountID] == nil
            VStack(spacing: 8) {
                if code != nil || waiting {
                    Text(code?.groupedCode ?? " ")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        ProgressView(value: Double(account.secondsLeft(at: now)), total: Double(account.period))
                        Text("\(account.secondsLeft(at: now))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                        Button("Copy") {
                            Task {
                                do {
                                    try await store.copyCode(of: account)
                                } catch {
                                    Dialogs.showProblem("The code was not copied", error)
                                }
                            }
                        }
                    }
                } else if let problem {
                    Text(problem.title)
                        .bold()
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(problem.suggestion)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.secretErrors[accountID] ?? "The secret is not read.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 240)
            .overlay(alignment: .bottomTrailing) {
                // The dot shows that the code is being fetched from Vault.
                if waiting {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .padding(4)
                }
            }
        }
    }
}
